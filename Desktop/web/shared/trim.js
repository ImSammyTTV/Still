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
  // The stretches that stay, in order.
  function kept(clip, cuts) {
    const out = []; let at = clip.start;
    for (const c of normalizeCuts(cuts, clip)) { if (c.start > at) out.push({ start: at, end: c.start }); at = Math.max(at, c.end); }
    if (clip.end > at) out.push({ start: at, end: clip.end });
    return out;
  }
  const keptLength = (clip, cuts) => kept(clip, cuts).reduce((sum, k) => sum + k.end - k.start, 0);
  // Where playback goes from `time`: the end of the cut it's in, or `time` itself.
  function skip(time, cuts) { for (const c of cuts || []) if (time >= c.start && time < c.end) return c.end; return time; }
  // The recording's time at a moment of the finished video, and the other way round (a time inside a cut
  // counts from where the cut ends).
  function sourceAt(t, segments) {
    let left = Math.max(0, t);
    for (const k of segments) { const len = k.end - k.start; if (left <= len) return k.start + left; left -= len; }
    return segments.length ? segments[segments.length - 1].end : 0;
  }
  function outputAt(time, segments) {
    let before = 0;
    for (const k of segments) { if (time < k.start) return before; if (time <= k.end) return before + time - k.start; before += k.end - k.start; }
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

  return { MIN_LENGTH, MIN_CUT, full, restore, setIn, setOut, isFull, length, position, timeAt, clock, recorderType, addCut, normalizeCuts, removeCut, kept, keptLength, skip, sourceAt, outputAt, pauses, levelsOf };
});
