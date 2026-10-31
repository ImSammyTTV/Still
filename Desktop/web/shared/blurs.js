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

  return { add, fit, fromDrag, fromPixels, at };
});
