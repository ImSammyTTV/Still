// Blur boxes over a video: a part of the picture hidden for a stretch of the recording (in its own time), such as a
// password typed on screen or a name that flashes by. Boxes are kept as shares of the video (0 to 1, from the top
// left) so they fit any export size, and follow the picture through zooms. Shared by the video editor and the tests;
// the Mac app's VideoBlur follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillBlurs = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const MIN = 0.01;

  // A new box at `time`, three seconds long, in the middle of the picture until it's drawn somewhere else.
  const add = (blurs, time, clip, box = { x: 0.35, y: 0.42, w: 0.3, h: 0.16 }) =>
    [...(blurs || []), { start: Math.max(clip.start, time), end: Math.min(clip.end, time + 3), ...fit(box) }].sort((a, b) => a.start - b.start);

  // A box kept inside the picture and at least 1% each way.
  function fit(box) {
    const w = clamp(Math.abs(box.w), MIN, 1), h = clamp(Math.abs(box.h), MIN, 1);
    return { x: clamp(box.w < 0 ? box.x + box.w : box.x, 0, 1 - w), y: clamp(box.h < 0 ? box.y + box.h : box.y, 0, 1 - h), w, h };
  }
  // The box between two points dragged on the picture (as shares).
  const fromDrag = (a, b) => fit({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) });
  // A box in the video's pixels, as shares, with a little room around it.
  const fromPixels = (box, width, height, pad = 4) => fit({ x: (box.x - pad) / width, y: (box.y - pad) / height, w: (box.w + pad * 2) / width, h: (box.h + pad * 2) / height });
  const at = (blurs, time) => (blurs || []).filter((b) => time >= b.start && time <= b.end);

  // ---- Moving, fading and see-through blurs ----
  // A blur can follow something across the screen: `keys` are its box at moments of the recording, and between two
  // keys it glides (easing in and out). Before the first key and after the last it stays put. With no keys it is
  // simply its own box. `fade` is how many seconds it takes to appear and to go, and `opacity` how much it hides
  // (1 hides fully; lower lets the picture show through).
  const ease = (u) => u * u * (3 - 2 * u);
  const KEY_GAP = 0.05; // Keys closer than this are the same key.
  function boxAt(b, time) {
    const keys = b.keys;
    if (!keys || !keys.length) return { x: b.x, y: b.y, w: b.w, h: b.h };
    if (time <= keys[0].t) return pick(keys[0]);
    const last = keys[keys.length - 1];
    if (time >= last.t) return pick(last);
    const i = keys.findIndex((k) => k.t > time), a = keys[i - 1], c = keys[i], u = ease((time - a.t) / (c.t - a.t));
    const mix = (p, q) => p + (q - p) * u;
    return { x: mix(a.x, c.x), y: mix(a.y, c.y), w: mix(a.w, c.w), h: mix(a.h, c.h) };
  }
  const pick = (k) => ({ x: k.x, y: k.y, w: k.w, h: k.h });
  function alphaAt(b, time) {
    if (time < b.start || time > b.end) return 0;
    const opacity = b.opacity == null ? 1 : clamp(b.opacity, 0, 1);
    const fade = Math.min(b.fade || 0, (b.end - b.start) / 2);
    const edge = fade > 0 ? Math.min(1, (time - b.start) / fade, (b.end - time) / fade) : 1;
    return opacity * ease(clamp(edge, 0, 1));
  }
  // What to draw at `time`: each showing blur's box, how strongly, and its place in the list.
  const frames = (blurs, time) => (blurs || []).map((b, index) => ({ ...boxAt(b, time), alpha: alphaAt(b, time), index })).filter((f) => f.alpha > 0);
  // The blur with its box set at `time`: a keyed blur gets (or updates) a key there, an unkeyed one just moves.
  function placeAt(b, time, box) {
    const fitted = fit(box);
    if (!b.keys || !b.keys.length) return { ...b, ...fitted };
    const keys = b.keys.filter((k) => Math.abs(k.t - time) >= KEY_GAP).concat([{ t: time, ...fitted }]).sort((p, q) => p.t - q.t);
    return { ...b, keys };
  }
  // Start following movement: a key at the blur's start with its box, and one at `time` with where it is then.
  function addKey(b, time) {
    const here = boxAt(b, time);
    const keys = b.keys && b.keys.length ? b.keys : [{ t: b.start, ...pick(b) }];
    return placeAt({ ...b, keys }, time, here);
  }
  // Take away the key nearest `time` (within a quarter second). The last one going makes the blur still again, where
  // that key had it.
  function removeKey(b, time) {
    if (!b.keys || !b.keys.length) return b;
    let best = -1;
    b.keys.forEach((k, i) => { if (Math.abs(k.t - time) <= 0.25 && (best < 0 || Math.abs(k.t - time) < Math.abs(b.keys[best].t - time))) best = i; });
    if (best < 0) return b;
    const keys = b.keys.filter((_, i) => i !== best);
    if (keys.length) return { ...b, keys };
    const { keys: _, ...rest } = b;
    return { ...rest, ...pick(b.keys[best]) };
  }
  // Which part of a box is under `p` (all in shares): a corner to resize from, the inside to move, or nothing.
  // `tol` is how near a corner counts, as a share of the picture.
  function handleAt(box, p, tol = 0.02) {
    const corners = { nw: [box.x, box.y], ne: [box.x + box.w, box.y], sw: [box.x, box.y + box.h], se: [box.x + box.w, box.y + box.h] };
    for (const [name, [cx, cy]] of Object.entries(corners)) if (Math.abs(p.x - cx) <= tol && Math.abs(p.y - cy) <= tol) return name;
    return p.x >= box.x && p.x <= box.x + box.w && p.y >= box.y && p.y <= box.y + box.h ? 'move' : null;
  }
  // The box after dragging `handle` by (dx, dy): a corner moves while the opposite one stays, the inside moves it all.
  function dragBox(box, handle, dx, dy) {
    if (handle === 'move') return fit({ x: clamp(box.x + dx, 0, 1 - box.w), y: clamp(box.y + dy, 0, 1 - box.h), w: box.w, h: box.h });
    const x1 = handle.includes('w') ? box.x + dx : box.x, x2 = handle.includes('e') ? box.x + box.w + dx : box.x + box.w;
    const y1 = handle.includes('n') ? box.y + dy : box.y, y2 = handle.includes('s') ? box.y + box.h + dy : box.y + box.h;
    return fromDrag({ x: clamp(x1, 0, 1), y: clamp(y1, 0, 1) }, { x: clamp(x2, 0, 1), y: clamp(y2, 0, 1) });
  }
  // A blur's timing after dragging one end of its bar on the timeline, kept at least 0.2 s long and inside the clip.
  function retime(b, end, time, clip) {
    if (end === 'start') return { ...b, start: clamp(time, clip.start, b.end - 0.2) };
    return { ...b, end: clamp(time, b.start + 0.2, clip.end) };
  }

  return { add, fit, fromDrag, fromPixels, at, boxAt, alphaAt, frames, placeAt, addKey, removeKey, handleAt, dragBox, retime };
});
