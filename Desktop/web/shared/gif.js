// A small GIF89a encoder with no dependencies. One palette is built from sample frames and shared by the
// whole GIF, so the colours stay steady; each frame then stores only what changed since the last one.
// It has no DOM needs, so the export runs it in a worker and the tests run it in Node.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillGIF = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const limits = { maxSeconds: 60, maxFrames: 600, maxFps: 24, maxSide: 1280, maxBytes: 256 * 1024 * 1024 };
  const TRANSPARENT = 255; // Palette slot for "same as the frame before"; real colours use the other 255.
  const BIN_BITS = 6, BINS = 1 << (BIN_BITS * 3);
  const binOf = (r, g, b) => ((r >> 2) << 12) | ((g >> 2) << 6) | (b >> 2);

  // Works out the size and frame rate for a clip, or says why it can't be a GIF. A clip that would need
  // too many frames gets a lower frame rate rather than a refusal.
  const plan = ({ duration, fps, width, sourceWidth, sourceHeight }) => {
    if (!(duration > 0) || !(sourceWidth > 0) || !(sourceHeight > 0)) return { ok: false, error: 'This video has no frames to export.' };
    if (duration > limits.maxSeconds + 0.05) return { ok: false, error: `GIFs are limited to ${limits.maxSeconds} seconds. Move the trim handles to keep ${limits.maxSeconds} seconds or less.` };
    const scale = Math.min(1, width / sourceWidth, limits.maxSide / sourceWidth, limits.maxSide / sourceHeight);
    const wanted = Math.min(fps, limits.maxFps);
    const frames = Math.max(1, Math.min(limits.maxFrames, Math.round(duration * wanted)));
    const rate = frames / duration;
    return { ok: true, width: Math.max(1, Math.round(sourceWidth * scale)), height: Math.max(1, Math.round(sourceHeight * scale)),
      frames, fps: Math.min(rate, wanted), lowered: rate < wanted - 0.5 };
  };

  // GIF delays are whole hundredths of a second. Rounding the running total keeps 12 fps at exactly
  // 12 fps over the clip instead of drifting. Browsers slow anything under 2 down to 10.
  const delayFor = (index, fps) => Math.max(2, Math.round((index + 1) * 100 / fps) - Math.round(index * 100 / fps));

  // Sample frames for the palette: evenly spread, the first frame always included.
  const sampleTimes = (start, length, count = 12) => Array.from({ length: count }, (_, i) => start + length * i / count);

  class Bytes {
    constructor() { this.data = new Uint8Array(1 << 16); this.length = 0; }
    reserve(extra) {
      const needed = this.length + extra;
      if (needed > limits.maxBytes) throw new Error(`The GIF went over ${Math.round(limits.maxBytes / 1048576)} MB. Try a smaller width, a lower frame rate or a shorter trim.`);
      if (needed <= this.data.length) return;
      let size = this.data.length; while (size < needed) size *= 2;
      const next = new Uint8Array(Math.min(size, limits.maxBytes)); next.set(this.data.subarray(0, this.length)); this.data = next;
    }
    byte(value) { this.reserve(1); this.data[this.length++] = value; }
    word(value) { this.reserve(2); this.data[this.length++] = value & 255; this.data[this.length++] = value >> 8; }
    bytes(values) { this.reserve(values.length); this.data.set(values, this.length); this.length += values.length; }
    text(value) { for (const c of value) this.byte(c.charCodeAt(0)); }
    result() { return this.data.slice(0, this.length); }
  }

  // Counts the colours in a frame, grouped into 64 steps per channel. Each group remembers its exact
  // average, so flat interface colours come out unchanged.
  class Histogram {
    constructor() { this.count = new Uint32Array(BINS); this.r = new Float64Array(BINS); this.g = new Float64Array(BINS); this.b = new Float64Array(BINS); }
    add(rgba) {
      for (let i = 0; i < rgba.length; i += 4) {
        const r = rgba[i], g = rgba[i + 1], b = rgba[i + 2], bin = binOf(r, g, b);
        this.count[bin]++; this.r[bin] += r; this.g[bin] += g; this.b[bin] += b;
      }
    }
    colors() {
      const list = [];
      for (let bin = 0; bin < BINS; bin++) {
        const n = this.count[bin];
        if (n) list.push({ r: this.r[bin] / n, g: this.g[bin] / n, b: this.b[bin] / n, weight: Math.sqrt(n) });
      }
      return list;
    }
  }

  // Median cut. Weighting by the square root of each colour's area keeps small details, such as a
  // cursor or a coloured button, from being lost to a large plain background.
  const medianCut = (colors, max) => {
    const box = (items) => {
      const low = [255, 255, 255], high = [0, 0, 0];
      let weight = 0;
      for (const c of items) {
        weight += c.weight;
        ['r', 'g', 'b'].forEach((k, i) => { low[i] = Math.min(low[i], c[k]); high[i] = Math.max(high[i], c[k]); });
      }
      const spans = high.map((h, i) => h - low[i]), span = Math.max(...spans);
      return { items, weight, axis: 'rgb'[spans.indexOf(span)], score: items.length > 1 ? span * Math.sqrt(weight) : -1 };
    };
    const boxes = [box(colors)];
    while (boxes.length < max) {
      let widest = 0;
      for (let i = 1; i < boxes.length; i++) if (boxes[i].score > boxes[widest].score) widest = i;
      const chosen = boxes[widest];
      if (chosen.score <= 0) break;
      const sorted = chosen.items.sort((a, b) => a[chosen.axis] - b[chosen.axis]);
      let half = chosen.weight / 2, cut = 0;
      while (cut < sorted.length - 2 && half > 0) half -= sorted[cut++].weight;
      cut = Math.max(1, cut);
      boxes[widest] = box(sorted.slice(0, cut));
      boxes.push(box(sorted.slice(cut)));
    }
    return boxes.map(({ items, weight }) => {
      const mean = (k) => Math.round(items.reduce((sum, c) => sum + c[k] * c.weight, 0) / weight);
      return [mean('r'), mean('g'), mean('b')];
    });
  };

  // GIF's LZW: codes grow from 9 to 12 bits, written low bit first in blocks of up to 255 bytes.
  const lzw = (out, pixels) => {
    const MIN_BITS = 8, CLEAR = 1 << MIN_BITS, END = CLEAR + 1, MAX_CODE = 4096;
    const SIZE = 9973, keys = new Int32Array(SIZE), codes = new Int16Array(SIZE); // An open hash table of (prefix, next pixel).
    let bits = MIN_BITS + 1, next = END + 1, buffer = 0, filled = 0;
    const block = new Uint8Array(255); let used = 0;
    const flushBlock = () => { if (used) { out.byte(used); out.bytes(block.subarray(0, used)); used = 0; } };
    const put = (value) => { block[used++] = value; if (used === 255) flushBlock(); };
    const emit = (code) => {
      buffer |= code << filled; filled += bits;
      while (filled >= 8) { put(buffer & 255); buffer >>>= 8; filled -= 8; }
    };
    const reset = () => { keys.fill(-1); bits = MIN_BITS + 1; next = END + 1; };
    out.byte(MIN_BITS);
    reset(); emit(CLEAR);
    let prefix = pixels[0];
    for (let i = 1; i < pixels.length; i++) {
      const pixel = pixels[i], key = (prefix << 8) | pixel;
      let slot = key % SIZE;
      while (keys[slot] !== -1 && keys[slot] !== key) slot = slot + 1 === SIZE ? 0 : slot + 1;
      if (keys[slot] === key) { prefix = codes[slot]; continue; }
      emit(prefix);
      if (next < MAX_CODE) {
        keys[slot] = key; codes[slot] = next;
        if (next === 1 << bits) bits++;
        next++;
      } else { emit(CLEAR); reset(); }
      prefix = pixel;
    }
    emit(prefix); emit(END);
    if (filled) put(buffer & 255);
    flushBlock();
    out.byte(0);
  };

  class Encoder {
    constructor(width, height) {
      this.width = width; this.height = height;
      this.out = new Bytes(); this.histogram = new Histogram();
      this.palette = null; this.lookup = new Int16Array(BINS).fill(-1);
      this.previous = null; this.pending = null;
    }
    // Sample frames set the palette; they aren't part of the GIF.
    addSample(rgba) { this.histogram.add(rgba); }
    start(first) {
      if (!this.histogram.count.some((n) => n)) this.histogram.add(first);
      this.palette = medianCut(this.histogram.colors(), TRANSPARENT);
      this.histogram = null;
      const { out, width, height } = this;
      out.text('GIF89a'); out.word(width); out.word(height);
      out.byte(0xf7); out.byte(0); out.byte(0); // A global table of 256 colours.
      for (let i = 0; i < 256; i++) { const c = this.palette[i] || [0, 0, 0]; out.byte(c[0]); out.byte(c[1]); out.byte(c[2]); }
      out.byte(0x21); out.byte(0xff); out.byte(11); out.text('NETSCAPE2.0'); out.byte(3); out.byte(1); out.word(0); out.byte(0); // Loop forever.
    }
    nearest(r, g, b) {
      const bin = binOf(r, g, b);
      let index = this.lookup[bin];
      if (index >= 0) return index;
      let best = Infinity;
      this.palette.forEach((c, i) => {
        const d = 2 * (c[0] - r) ** 2 + 4 * (c[1] - g) ** 2 + 3 * (c[2] - b) ** 2;
        if (d < best) { best = d; index = i; }
      });
      this.lookup[bin] = index;
      return index;
    }
    addFrame(rgba, delay) {
      if (!this.palette) this.start(rgba);
      const { width, height, previous } = this;
      const indexed = new Uint8Array(width * height);
      for (let p = 0, i = 0; p < indexed.length; p++, i += 4) indexed[p] = this.nearest(rgba[i], rgba[i + 1], rgba[i + 2]);
      let left = 0, top = 0, right = width - 1, bottom = height - 1;
      if (previous) {
        left = width; top = height; right = -1; bottom = -1;
        for (let y = 0, p = 0; y < height; y++) for (let x = 0; x < width; x++, p++) {
          if (indexed[p] === previous[p]) continue;
          if (x < left) left = x; if (x > right) right = x;
          if (y < top) top = y; if (y > bottom) bottom = y;
        }
        // Nothing changed: the frame before simply stays up for longer.
        if (right < 0) { this.pending.delay += delay; return; }
      }
      const w = right - left + 1, h = bottom - top + 1, pixels = new Uint8Array(w * h);
      for (let y = 0, q = 0; y < h; y++) {
        const row = (top + y) * width + left;
        for (let x = 0; x < w; x++, q++) {
          const value = indexed[row + x];
          pixels[q] = previous && previous[row + x] === value ? TRANSPARENT : value;
        }
      }
      this.flush();
      this.pending = { left, top, w, h, pixels, delay, transparent: !!previous };
      this.previous = indexed;
    }
    flush() {
      const frame = this.pending, out = this.out;
      if (!frame) return;
      this.pending = null;
      for (let delay = frame.delay, first = true; delay > 0 || first; first = false) {
        const part = Math.min(delay, 65535); delay -= part;
        out.byte(0x21); out.byte(0xf9); out.byte(4);
        out.byte((1 << 2) | (frame.transparent || !first ? 1 : 0)); // Keep this frame up under the next one.
        out.word(part); out.byte(TRANSPARENT); out.byte(0);
        out.byte(0x2c);
        if (first) { out.word(frame.left); out.word(frame.top); out.word(frame.w); out.word(frame.h); out.byte(0); lzw(out, frame.pixels); }
        else { out.word(0); out.word(0); out.word(1); out.word(1); out.byte(0); lzw(out, Uint8Array.of(TRANSPARENT)); } // Very long holds need a second frame.
      }
    }
    finish() {
      if (!this.pending) throw new Error('The GIF has no frames.');
      this.flush();
      this.out.byte(0x3b);
      return this.out.result();
    }
  }

  return { limits, plan, delayFor, sampleTimes, Encoder };
});
