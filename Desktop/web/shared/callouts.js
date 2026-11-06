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

  // ---- Moving, fading and see-through callouts (the same rules as blurs) ----
  // `keys` are its shape at moments of the recording ({ t, x, y, and x2, y2 for an arrow or w, h for a box }); between
  // two keys it glides, easing in and out, and before the first and after the last it stays put. `fade` is how many
  // seconds it takes to appear and to go (unset: the quick 0.2 s ramp), and `opacity` how solid it is (1 fully).
  const SHAPE = ['x', 'y', 'x2', 'y2', 'w', 'h'];
  const KEY_GAP = 0.05;
  const ease = (u) => u * u * (3 - 2 * u);
  const shapeOf = (c) => { const s = {}; for (const k of SHAPE) if (typeof c[k] === 'number') s[k] = c[k]; return s; };
  function shapeAt(c, time) {
    const keys = c.keys;
    if (!keys || !keys.length) return shapeOf(c);
    if (time <= keys[0].t) return shapeOf(keys[0]);
    const last = keys[keys.length - 1];
    if (time >= last.t) return shapeOf(last);
    const i = keys.findIndex((k) => k.t > time), a = keys[i - 1], b = keys[i], u = ease((time - a.t) / (b.t - a.t)), out = {};
    for (const k of SHAPE) if (typeof a[k] === 'number' && typeof b[k] === 'number') out[k] = a[k] + (b[k] - a[k]) * u;
    return out;
  }
  function alphaAt(c, time) {
    if (time < c.start || time > c.end) return 0;
    const opacity = c.opacity == null ? 1 : clamp(c.opacity);
    if (c.fade == null) {
      const ramp = Math.min(FADE, (c.end - c.start) / 3);
      return opacity * (ramp > 0 ? Math.min(1, (time - c.start) / ramp, (c.end - time) / ramp) : 1);
    }
    const fade = Math.min(c.fade, (c.end - c.start) / 2);
    const edge = fade > 0 ? Math.min(1, (time - c.start) / fade, (c.end - time) / fade) : 1;
    return opacity * ease(clamp(edge));
  }
  // The callout with its shape changed at `time`: a keyed one gets (or updates) a key there, an unkeyed one just moves.
  function placeAt(c, time, patch) {
    if (!c.keys || !c.keys.length) return { ...c, ...patch };
    const key = { t: time, ...shapeAt(c, time), ...patch };
    return { ...c, keys: c.keys.filter((k) => Math.abs(k.t - time) >= KEY_GAP).concat([key]).sort((p, q) => p.t - q.t) };
  }
  // Start following movement: a key at its start with its shape, and one at `time` with where it is then.
  function addKey(c, time) {
    const keys = c.keys && c.keys.length ? c.keys : [{ t: c.start, ...shapeOf(c) }];
    return placeAt({ ...c, keys }, time, shapeAt({ ...c, keys }, time));
  }
  const hasKey = (c, time) => (c.keys || []).some((k) => Math.abs(k.t - time) <= 0.25);
  // Takes away the key nearest `time` (within a quarter second); the last one going makes it still again, there.
  function removeKey(c, time) {
    if (!c.keys || !c.keys.length) return c;
    let best = -1;
    c.keys.forEach((k, i) => { if (Math.abs(k.t - time) <= 0.25 && (best < 0 || Math.abs(k.t - time) < Math.abs(c.keys[best].t - time))) best = i; });
    if (best < 0) return c;
    const keys = c.keys.filter((_, i) => i !== best);
    if (keys.length) return { ...c, keys };
    const { keys: _, ...rest } = c;
    return { ...rest, ...shapeOf(c.keys[best]) };
  }

  // The callouts showing at `time`, each with its shape then and how opaque it is (0 to 1).
  const at = (callouts, time) => (callouts || []).filter((c) => time >= c.start && time <= c.end)
    .map((c) => ({ callout: { ...c, ...shapeAt(c, time) }, alpha: alphaAt(c, time) }));

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

  return { KINDS, COLORS, FADE, add, at, fromClicks, head, shapeAt, alphaAt, placeAt, addKey, removeKey, hasKey };
});
