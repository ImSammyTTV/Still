const test = require('node:test');
const assert = require('node:assert/strict');
const GIF = require('../web/shared/gif');

// A small GIF reader, so the tests check what a decoder would really see.
function decode(bytes) {
  let at = 0;
  const byte = () => bytes[at++], word = () => byte() | (byte() << 8);
  assert.equal(String.fromCharCode(...bytes.subarray(0, 6)), 'GIF89a');
  at = 6;
  const width = word(), height = word(), packed = byte(); at += 2;
  assert.ok(packed & 0x80, 'has a global palette');
  const colors = 2 << (packed & 7), palette = [];
  for (let i = 0; i < colors; i++) palette.push([byte(), byte(), byte()]);
  const canvas = new Array(width * height).fill(null), frames = [];
  let control = {}, loops = false;
  for (;;) {
    const kind = byte();
    if (kind === 0x3b) break;
    if (kind === 0x21) {
      const label = byte();
      if (label === 0xf9) {
        at++; const flags = byte(), delay = word(), transparent = byte(); at++;
        control = { delay, transparent: flags & 1 ? transparent : -1, disposal: (flags >> 2) & 7 };
      } else {
        const start = at;
        while (bytes[at]) at += bytes[at] + 1;
        at++;
        if (label === 0xff) loops = String.fromCharCode(...bytes.subarray(start + 1, start + 12)) === 'NETSCAPE2.0';
      }
    } else if (kind === 0x2c) {
      const left = word(), top = word(), w = word(), h = word(); assert.equal(byte() & 0x80, 0, 'no local palette');
      const pixels = lzw(byte(), () => { const data = []; for (let n = byte(); n; n = byte()) { for (let i = 0; i < n; i++) data.push(byte()); } return data; });
      assert.equal(pixels.length, w * h, 'a whole frame of pixels');
      pixels.forEach((value, i) => {
        if (value === control.transparent) return;
        canvas[(top + Math.floor(i / w)) * width + left + i % w] = palette[value];
      });
      frames.push({ ...control, left, top, w, h, canvas: canvas.slice() });
    } else assert.fail(`unexpected block ${kind} at ${at}`);
  }
  return { width, height, frames, loops, palette };
}

function lzw(minBits, read) {
  const data = read(), clear = 1 << minBits, end = clear + 1, out = [];
  let bits = minBits + 1, table = [], buffer = 0, filled = 0, at = 0, previous = null;
  const reset = () => { table = []; for (let i = 0; i < clear; i++) table[i] = [i]; table[clear] = table[end] = []; bits = minBits + 1; previous = null; };
  reset();
  for (;;) {
    while (filled < bits) { assert.ok(at < data.length, 'stream ended without an end code'); buffer |= data[at++] << filled; filled += 8; }
    const code = buffer & ((1 << bits) - 1); buffer >>>= bits; filled -= bits;
    if (code === clear) { reset(); continue; }
    if (code === end) return out;
    let entry;
    if (code < table.length) entry = table[code];
    else { assert.ok(previous && code === table.length, `bad code ${code}`); entry = [...previous, previous[0]]; }
    out.push(...entry);
    if (previous && table.length < 4096) {
      table.push([...previous, entry[0]]);
      if (table.length === 1 << bits && bits < 12) bits++;
    }
    previous = entry;
  }
}

const frame = (w, h, paint) => {
  const rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const [r, g, b] = paint(x, y), i = (y * w + x) * 4;
    rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255;
  }
  return rgba;
};
const near = (a, b, tolerance) => a.every((v, i) => Math.abs(v - b[i]) <= tolerance);

test('flat interface colours survive exactly and the GIF loops', () => {
  const encoder = new GIF.Encoder(8, 4);
  const paint = (x) => (x < 4 ? [255, 255, 255] : [30, 60, 200]);
  encoder.addSample(frame(8, 4, paint));
  encoder.addFrame(frame(8, 4, paint), 10);
  const gif = decode(encoder.finish());
  assert.equal(gif.width, 8); assert.equal(gif.height, 4); assert.ok(gif.loops);
  assert.equal(gif.frames.length, 1);
  assert.deepEqual(gif.frames[0].canvas[0], [255, 255, 255]);
  assert.deepEqual(gif.frames[0].canvas[7], [30, 60, 200]);
});

test('later frames store only the part that changed', () => {
  const encoder = new GIF.Encoder(20, 20);
  const plain = frame(20, 20, () => [240, 240, 240]), dot = frame(20, 20, (x, y) => (x >= 5 && x < 8 && y >= 10 && y < 12 ? [200, 0, 0] : [240, 240, 240]));
  encoder.addSample(plain); encoder.addSample(dot);
  encoder.addFrame(plain, 8); encoder.addFrame(dot, 8);
  const gif = decode(encoder.finish());
  assert.equal(gif.frames.length, 2);
  const { left, top, w, h, disposal, canvas } = gif.frames[1];
  assert.deepEqual([left, top, w, h], [5, 10, 3, 2]);
  assert.equal(disposal, 1, 'the previous frame stays underneath');
  assert.deepEqual(canvas[10 * 20 + 6], [200, 0, 0]);
  assert.deepEqual(canvas[0], [240, 240, 240]);
});

test('a frame identical to the last one just lengthens it', () => {
  const encoder = new GIF.Encoder(4, 4), same = frame(4, 4, () => [10, 20, 30]);
  encoder.addFrame(same, 8); encoder.addFrame(same, 9); encoder.addFrame(same, 7);
  const gif = decode(encoder.finish());
  assert.equal(gif.frames.length, 1);
  assert.equal(gif.frames[0].delay, 24);
});

test('LZW stays correct past a full code table', () => {
  // Noise forces the dictionary to fill and clear several times.
  let seed = 12345;
  const random = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 16;
  const rows = 200, noisy = frame(rows, rows, () => [random() & 255, random() & 255, random() & 255]);
  const encoder = new GIF.Encoder(rows, rows);
  encoder.addFrame(noisy, 10);
  const gif = decode(encoder.finish());
  assert.equal(gif.frames[0].canvas.filter(Boolean).length, rows * rows);
  // Colour accuracy with 255 colours for random noise is limited, but every pixel must be in range.
  assert.ok(near(gif.frames[0].canvas[0], [noisy[0], noisy[1], noisy[2]], 120));
});

test('a gradient keeps its detail in 255 colours', () => {
  const size = 64, paint = (x, y) => [x * 4, y * 4, 128], encoder = new GIF.Encoder(size, size);
  encoder.addFrame(frame(size, size, paint), 10);
  const gif = decode(encoder.finish());
  for (let y = 0; y < size; y += 7) for (let x = 0; x < size; x += 7) assert.ok(near(gif.frames[0].canvas[y * size + x], paint(x, y), 24), `${x},${y}`);
});

test('a very long hold is split rather than overflowing the delay field', () => {
  const encoder = new GIF.Encoder(2, 2), same = frame(2, 2, () => [1, 2, 3]);
  encoder.addFrame(same, 65000); encoder.addFrame(same, 1000);
  const gif = decode(encoder.finish());
  assert.deepEqual(gif.frames.map((f) => f.delay), [65535, 465]);
  assert.deepEqual(gif.frames[1].canvas[0], gif.frames[0].canvas[0]);
});

test('finishing with no frames is an error, not an empty file', () => {
  assert.throws(() => new GIF.Encoder(2, 2).finish(), /no frames/);
});

test('an oversized GIF stops with a real error', () => {
  const max = GIF.limits.maxBytes; GIF.limits.maxBytes = 2000;
  try {
    let seed = 1;
    const random = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) >> 16;
    const encoder = new GIF.Encoder(200, 200);
    assert.throws(() => { encoder.addFrame(frame(200, 200, () => [random() & 255, random() & 255, random() & 255]), 10); encoder.finish(); }, /went over/);
  } finally { GIF.limits.maxBytes = max; }
});

test('the plan keeps size and frame rate within the limits', () => {
  const clip = { sourceWidth: 2560, sourceHeight: 1440 };
  assert.deepEqual(GIF.plan({ ...clip, duration: 5, fps: 12, width: 800 }), { ok: true, width: 800, height: 450, frames: 60, fps: 12, lowered: false });
  // Never upscaled, and never over the size limit on either side.
  assert.equal(GIF.plan({ sourceWidth: 300, sourceHeight: 200, duration: 1, fps: 12, width: 800 }).width, 300);
  assert.equal(GIF.plan({ sourceWidth: 1000, sourceHeight: 4000, duration: 1, fps: 12, width: 1280 }).height, 1280);
  assert.equal(GIF.plan({ ...clip, duration: 1, fps: 60, width: 800 }).fps, 24);
  // A long clip gets fewer frames per second rather than a refusal.
  const long = GIF.plan({ ...clip, duration: 60, fps: 24, width: 800 });
  assert.equal(long.frames, GIF.limits.maxFrames); assert.equal(long.fps, 10); assert.ok(long.lowered);
  // Over the length limit it explains what to do.
  assert.match(GIF.plan({ ...clip, duration: 61, fps: 12, width: 800 }).error, /limited to 60 seconds/);
  assert.equal(GIF.plan({ ...clip, duration: 0, fps: 12, width: 800 }).ok, false);
});

test('delays add up to the clip length without drifting', () => {
  for (const fps of [5, 10, 12, 15, 24]) {
    let total = 0;
    for (let i = 0; i < fps * 10; i++) total += GIF.delayFor(i, fps);
    assert.equal(total, 1000, `${fps} fps`);
  }
  assert.ok(GIF.delayFor(0, 1000) >= 2);
});

test('palette samples are spread through the clip', () => {
  assert.deepEqual(GIF.sampleTimes(2, 4, 4), [2, 3, 4, 5]);
});
