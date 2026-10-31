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

  return { MIN_LENGTH, full, restore, setIn, setOut, isFull, length, position, timeAt, clock, recorderType };
});
