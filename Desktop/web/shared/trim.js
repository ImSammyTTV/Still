// Pure trim logic for the video editor, shared by the page and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillTrim = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const MIN_LENGTH = 0.2; // The shortest clip the handles allow, as on the Mac.
  const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

  const full = (duration) => ({ start: 0, end: duration });
  // In and Out can't cross; on a clip shorter than the minimum they simply keep the whole clip.
  const setIn = (trim, time, duration) => ({ ...trim, start: clamp(time, 0, Math.max(0, Math.min(duration, trim.end) - MIN_LENGTH)) });
  const setOut = (trim, time, duration) => ({ ...trim, end: clamp(time, Math.min(duration, trim.start + MIN_LENGTH), duration) });
  const isFull = (trim, duration) => trim.start <= 0.01 && trim.end >= duration - 0.01;
  // Saved trim points, checked against the file as it is now: anything missing, out of range or too short to
  // keep means the whole recording.
  const restore = (saved, duration) => {
    const start = Number(saved && saved.start), end = Number(saved && saved.end);
    if (!Number.isFinite(start) || !Number.isFinite(end)) return full(duration);
    const trim = { start: clamp(start, 0, duration), end: clamp(end, 0, duration) };
    return trim.end - trim.start >= MIN_LENGTH ? trim : full(duration);
  };
  const length = (trim) => Math.max(0, trim.end - trim.start);
  const position = (time, duration) => duration > 0 ? clamp(time / duration, 0, 1) : 0;
  const timeAt = (x, width, duration) => width > 0 ? clamp(x / width, 0, 1) * duration : 0;

  // 0:03.4 — tenths matter when you are placing a cut.
  const clock = (seconds) => {
    const tenths = Math.round(Math.max(0, seconds) * 10);
    return `${Math.floor(tenths / 600)}:${String(Math.floor(tenths / 10) % 60).padStart(2, '0')}.${tenths % 10}`;
  };

  // The recorder format for a trimmed copy: the source's container if the engine can write it, otherwise
  // the other one. An empty type means this web engine can't re-encode video at all.
  const recorderType = (ext, supported) => {
    const mp4 = ['video/mp4;codecs=avc1.640028,mp4a.40.2', 'video/mp4;codecs=avc1,opus', 'video/mp4'];
    const webm = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'];
    const type = (ext === 'mp4' ? [...mp4, ...webm] : [...webm, ...mp4]).find(supported) || '';
    return { type, ext: type.startsWith('video/mp4') ? 'mp4' : 'webm' };
  };

  // ---- Cuts: stretches taken out of the middle -------------------------------------------------------
  // A cut is { start, end } in the recording's own time. Cuts are kept sorted, inside the clip, at least
  // MIN_CUT long, and merged where they touch. The Mac app's VideoTimeline follows the same rules.
  const MIN_CUT = 0.1;
  function addCut(cuts, a, b, clip) {
    const start = clamp(Math.min(a, b), clip.start, clip.end), end = clamp(Math.max(a, b), clip.start, clip.end);
    if (end - start < MIN_CUT) return normalizeCuts(cuts, clip);
    return normalizeCuts([...(cuts || []), { start, end }], clip);
  }
  function normalizeCuts(cuts, clip) {
    const sorted = (cuts || []).map((c) => ({ start: clamp(Number(c.start), clip.start, clip.end), end: clamp(Number(c.end), clip.start, clip.end) }))
      .filter((c) => Number.isFinite(c.start) && Number.isFinite(c.end) && c.end - c.start >= MIN_CUT).sort((x, y) => x.start - y.start);
    const out = [];
    for (const c of sorted) { const last = out[out.length - 1]; if (last && c.start <= last.end) last.end = Math.max(last.end, c.end); else out.push({ ...c }); }
    return out;
  }
  const removeCut = (cuts, index) => (cuts || []).filter((_, i) => i !== index);
  // ---- Fast-forward: stretches that play faster -----------------------------------------------------
  // A fast-forward is { start, end, rate } in the recording's own time, rate 2, 4 or 8. They're kept sorted, inside
  // the clip, at least MIN_SKIM long, and never overlap (a later one starts where an earlier one ends).
  const MIN_SKIM = 0.5, RATES = [2, 4, 8];
  function normalizeSkims(skims, clip) {
    const sorted = (skims || []).map((k) => ({ start: clamp(Number(k.start), clip.start, clip.end), end: clamp(Number(k.end), clip.start, clip.end), rate: RATES.includes(Number(k.rate)) ? Number(k.rate) : 4 }))
      .filter((k) => Number.isFinite(k.start) && Number.isFinite(k.end)).sort((x, y) => x.start - y.start);
    const out = [];
    for (const k of sorted) { const last = out[out.length - 1]; if (last && k.start < last.end) k.start = last.end; if (k.end - k.start >= MIN_SKIM) out.push(k); }
    return out;
  }
  // A new fast-forward from `time`, five seconds long or to the end of the clip or the next one.
  function addSkim(skims, time, clip, rate = 4) {
    const list = normalizeSkims(skims, clip);
    if (list.some((k) => time >= k.start && time < k.end)) return list;
    const next = list.find((k) => k.start > time), end = Math.min(clip.end, time + 5, next ? next.start : Infinity);
    return normalizeSkims([...list, { start: time, end, rate }], clip);
  }
  // Waits worth speeding up: stretches of at least `minimum` seconds where the picture barely moves (every change
  // between samples under `still`) and nobody speaks (outside `speech`), such as a progress bar, an install or a
  // page loading. `changes[i]` is the difference between the pictures at start + i*step and start + (i+1)*step.
  // Each becomes a fast-forward at `rate` that leaves `keep` seconds at either end, so the wait is seen to begin
  // and to end.
  function waits(changes, step, speech, { start = 0, minimum = 4, still = 0.02, keep = 0.5, rate = 4 } = {}) {
    const calm = [];
    let from = null;
    (changes || []).forEach((v, i) => {
      if (v < still) { if (from === null) from = start + i * step; }
      else if (from !== null) { calm.push({ start: from, end: start + i * step }); from = null; }
    });
    if (from !== null) calm.push({ start: from, end: start + (changes || []).length * step });
    const out = [];
    for (const c of calm) {
      let pieces = [c];
      for (const s of speech || []) pieces = pieces.flatMap((p) => (s.end <= p.start || s.start >= p.end ? [p] : [{ start: p.start, end: s.start }, { start: s.end, end: p.end }].filter((q) => q.end > q.start)));
      for (const p of pieces) if (p.end - p.start >= minimum) out.push({ start: p.start + keep, end: p.end - keep, rate });
    }
    return out;
  }
  const skimAt = (time, skims) => { for (const k of skims || []) if (time >= k.start && time < k.end) return k.rate; return 1; };

  // The stretches that stay, in order. With fast-forwards they're split where one starts or ends, and the parts
  // inside one carry its rate.
  function kept(clip, cuts, skims) {
    const out = []; let at = clip.start;
    for (const c of normalizeCuts(cuts, clip)) { if (c.start > at) out.push({ start: at, end: c.start }); at = Math.max(at, c.end); }
    if (clip.end > at) out.push({ start: at, end: clip.end });
    const fast = normalizeSkims(skims, clip);
    if (!fast.length) return out;
    const split = [];
    for (const k of out) {
      let from = k.start;
      for (const f of fast) {
        if (f.end <= from || f.start >= k.end) continue;
        if (f.start > from) split.push({ start: from, end: f.start });
        const end = Math.min(k.end, f.end); split.push({ start: Math.max(from, f.start), end, rate: f.rate }); from = end;
      }
      if (k.end - from > 1e-9) split.push({ start: from, end: k.end });
    }
    return split;
  }
  // How long a stretch lasts in the finished video.
  const played = (k) => (k.end - k.start) / (k.rate || 1);
  const keptLength = (clip, cuts, skims) => kept(clip, cuts, skims).reduce((sum, k) => sum + played(k), 0);
  // Where playback goes from `time`: the end of the cut it's in, or `time` itself.
  function skip(time, cuts) { for (const c of cuts || []) if (time >= c.start && time < c.end) return c.end; return time; }
  // The recording's time at a moment of the finished video, and the other way round (a time inside a cut
  // counts from where the cut ends).
  function sourceAt(t, segments) {
    let left = Math.max(0, t);
    for (const k of segments) { const len = played(k); if (left <= len) return k.start + left * (k.rate || 1); left -= len; }
    return segments.length ? segments[segments.length - 1].end : 0;
  }
  function outputAt(time, segments) {
    let before = 0;
    for (const k of segments) { if (time < k.start) return before; if (time <= k.end) return before + (time - k.start) / (k.rate || 1); before += played(k); }
    return before;
  }

  // ---- Tighten Pauses: long silences found in the sound, as cuts ------------------------------------
  // `levels` is the loudness in decibels for each `step` seconds of the recording. A stretch counts as silent
  // when it's well under the speaking level (25 dB below the loud end, between -60 and -30 dB);
  // one longer than `minimum` seconds becomes a cut that leaves `keep` seconds of quiet each side, so speech
  // isn't clipped and the rhythm stays natural. The Mac app's AudioPauses follows the same rules.
  function pauses(levels, step, clip, { minimum = 1, keep = 0.3 } = {}) {
    const loud = [...levels].filter(Number.isFinite).sort((a, b) => a - b);
    if (!loud.length) return [];
    const speaking = loud[Math.floor(loud.length * 0.9)];
    const threshold = Math.min(-30, Math.max(-60, speaking - 25));
    const found = []; let begin = null;
    levels.forEach((level, i) => {
      const quiet = !(level > threshold);
      if (quiet && begin === null) begin = i;
      if ((!quiet || i === levels.length - 1) && begin !== null) {
        const end = quiet ? i + 1 : i;
        const a = begin * step, b = end * step;
        if (b - a >= minimum) found.push({ start: a + keep, end: b - keep });
        begin = null;
      }
    });
    return normalizeCuts(found, clip);
  }
  // ---- Music ducking: where someone is speaking, and how far the music dips there ----------------------
  // Stretches of the recording above the speaking threshold (as `pauses` judges it), joined across gaps shorter
  // than `gap` and padded by `pad` each side.
  function speech(levels, step, { gap = 0.4, pad = 0.2 } = {}) {
    const loud = [...levels].filter(Number.isFinite).sort((a, b) => a - b);
    if (!loud.length) return [];
    const threshold = Math.min(-30, Math.max(-60, loud[Math.floor(loud.length * 0.9)] - 25));
    const out = []; let begin = null;
    levels.forEach((level, i) => {
      const talking = level > threshold;
      if (talking && begin === null) begin = i;
      if ((!talking || i === levels.length - 1) && begin !== null) {
        const start = Math.max(0, begin * step - pad), end = (talking ? i + 1 : i) * step + pad;
        const last = out[out.length - 1];
        if (last && start - last.end < gap) last.end = end; else out.push({ start, end });
        begin = null;
      }
    });
    return out;
  }
  // The music's share of its volume at `time`: `low` while someone speaks, easing over `ramp` seconds either side.
  function duck(time, ranges, { low = 0.3, ramp = 0.15 } = {}) {
    let level = 1;
    for (const r of ranges || []) {
      const into = Math.min(time - (r.start - ramp), (r.end + ramp) - time);
      if (into <= 0) continue;
      level = Math.min(level, into >= ramp ? low : 1 - (1 - low) * (into / ramp));
    }
    return level;
  }

  // Loudness in decibels for each `step` seconds of mono samples.
  function levelsOf(samples, rate, step = 0.05) {
    const size = Math.max(1, Math.round(rate * step)), out = [];
    for (let at = 0; at < samples.length; at += size) {
      let sum = 0; const end = Math.min(samples.length, at + size);
      for (let i = at; i < end; i++) sum += samples[i] * samples[i];
      const rms = Math.sqrt(sum / Math.max(1, end - at));
      out.push(rms > 0 ? 20 * Math.log10(rms) : -120);
    }
    return out;
  }

  return { MIN_LENGTH, MIN_CUT, full, restore, setIn, setOut, isFull, length, position, timeAt, clock, recorderType, addCut, normalizeCuts, removeCut, MIN_SKIM, RATES, normalizeSkims, addSkim, skimAt, waits, kept, keptLength, skip, sourceAt, outputAt, pauses, levelsOf, speech, duck };
});
