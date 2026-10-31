// Callouts over a video: an arrow, a box or a spotlight shown for a stretch of the recording (in its own time).
// Places are shares of the video (0 to 1, from the top left), so callouts fit any export size and follow the
// picture through zooms; an arrow's tip is (x, y) and its tail (x2, y2). They fade in and out over 0.2 s. Point at
// Clicks makes an arrow for each recorded click. Shared by the video editor and the tests; the Mac app's
// VideoCallout follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillCallouts = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const KINDS = ['arrow', 'box', 'spotlight'];
  const COLORS = ['#FF453A', '#FFD60A', '#32D74B', '#0A84FF', '#FFFFFF'];
  const FADE = 0.2;
  const clamp = (v) => Math.min(1, Math.max(0, v));

  // A new callout at `time`, three seconds long, in the middle until it's drawn somewhere else.
  function add(callouts, kind, time, clip) {
    const base = { kind, start: Math.max(clip.start, time), end: Math.min(clip.end, time + 3), color: COLORS[0] };
    const shape = kind === 'arrow' ? { x: 0.5, y: 0.5, x2: 0.38, y2: 0.36 } : { x: 0.35, y: 0.35, w: 0.3, h: 0.3 };
    return [...(callouts || []), { ...base, ...shape }].sort((a, b) => a.start - b.start);
  }

  // The callouts showing at `time`, each with how opaque it is (0 to 1).
  const at = (callouts, time) => (callouts || []).filter((c) => time >= c.start && time <= c.end).map((c) => {
    const ramp = Math.min(FADE, (c.end - c.start) / 3);
    return { callout: c, alpha: ramp > 0 ? Math.min(1, (time - c.start) / ramp, (c.end - time) / ramp) : 1 };
  });

  // An arrow for each recorded click ([time, x, y]) inside the clip: it appears 0.4 s before the click and stays
  // 1.2 s after, its tail up and to the left (or wherever there's room). Clicks within a second of the last are
  // skipped, so a burst gets one arrow.
  function fromClicks(clicks, clip) {
    const out = []; let last = -Infinity;
    for (const [t, x, y] of clicks || []) {
      if (t < clip.start || t > clip.end || t - last < 1) continue;
      last = t;
      const dx = x > 0.2 ? -0.12 : 0.12, dy = y > 0.2 ? -0.12 : 0.12;
      out.push({ kind: 'arrow', start: Math.max(clip.start, t - 0.4), end: Math.min(clip.end, t + 1.2), color: COLORS[0], x: clamp(x), y: clamp(y), x2: clamp(x + dx), y2: clamp(y + dy) });
    }
    return out;
  }

  // The arrow's head, as two points beside the tip, `size` long, at about 28° to the shaft (in any units).
  function head(tail, tip, size) {
    const angle = Math.atan2(tip.y - tail.y, tip.x - tail.x);
    return [-0.5, 0.5].map((spread) => ({ x: tip.x - size * Math.cos(angle + spread), y: tip.y - size * Math.sin(angle + spread) }));
  }

  return { KINDS, COLORS, FADE, add, at, fromClicks, head };
});
