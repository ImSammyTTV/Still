// Zooms and click rings for the video editor, shared by the page and the tests. They follow the Mac app: a zoom
// eases in and out over the first and last 0.4 seconds of its stretch, centred on a point given as shares of the
// video (0 to 1, from the top left), and never shows anything outside the video.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillZoom = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
  const DEFAULT_SCALE = 1.7;
  const RING_LIFE = 0.6; // Seconds a click ring stays on screen.

  // How far in the video is zoomed at `time`, and around which point.
  function at(zooms, time) {
    for (const z of zooms || []) {
      if (time < z.start || time > z.end) continue;
      const ramp = Math.min(0.4, (z.end - z.start) / 3);
      const raw = ramp > 0 ? clamp(Math.min((time - z.start) / ramp, (z.end - time) / ramp), 0, 1) : 1;
      const ease = raw * raw * (3 - 2 * raw);
      return { scale: 1 + (z.scale - 1) * ease, x: z.x, y: z.y };
    }
    return { scale: 1, x: 0.5, y: 0.5 };
  }

  // The part of a width × height picture that fills the frame at that zoom.
  function source(width, height, zoom) {
    const w = width / zoom.scale, h = height / zoom.scale;
    return { x: clamp(zoom.x * width - w / 2, 0, width - w), y: clamp(zoom.y * height - h / 2, 0, height - h), w, h };
  }

  // Where the pointer was nearest to `time`, from the recording's path; the middle if there is no path.
  function pointerAt(pointer, time) {
    let best = null;
    for (const p of pointer || []) if (!best || Math.abs(p[0] - time) < Math.abs(best[0] - time)) best = p;
    return best ? { x: best[1], y: best[2] } : { x: 0.5, y: 0.5 };
  }

  // A two-second zoom starting just before the playhead, kept inside the trimmed part.
  function add(zooms, time, trim, pointer) {
    const focus = pointerAt(pointer, time);
    const zoom = { start: Math.max(trim.start, time - 0.2), end: Math.min(trim.end, time + 2), scale: DEFAULT_SCALE, x: focus.x, y: focus.y };
    return [...(zooms || []).filter((z) => z.end <= zoom.start || z.start >= zoom.end), zoom].sort((a, b) => a.start - b.start);
  }

  // One zoom per burst of clicks, as the Mac's Auto Zoom: a click within 1.8 seconds of the last zoom's start joins it.
  function auto(clicks, trim) {
    const zooms = [];
    for (const [time, x, y] of clicks || []) {
      if (time < trim.start || time > trim.end) continue;
      const last = zooms[zooms.length - 1];
      if (last && time - last.start < 1.8) continue;
      const zoom = { start: Math.max(trim.start, time - 0.35), end: Math.min(trim.end, time + 1.65), scale: DEFAULT_SCALE, x, y };
      // Overlapping zooms would jump from one to the other: the earlier one gives way.
      if (last && last.end > zoom.start) last.end = zoom.start;
      zooms.push(zoom);
    }
    return zooms;
  }

  // The click rings showing at `time`, each with how far along it is (0 to 1).
  function rings(clicks, time) {
    return (clicks || []).filter(([t]) => time >= t && time < t + RING_LIFE).map(([t, x, y]) => ({ x, y, progress: (time - t) / RING_LIFE }));
  }

  return { DEFAULT_SCALE, RING_LIFE, at, source, pointerAt, add, auto, rings };
});
