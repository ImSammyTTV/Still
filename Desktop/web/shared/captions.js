// Text captions over a video: a title, a step, a note, each shown for a stretch of the recording (in its own time)
// in a dark rounded pill near the top, middle or bottom. They fade in and out over a quarter of a second. Shared by
// the video editor and the tests; the Mac app's VideoCaption follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillCaptions = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const SIZES = { small: 0.045, medium: 0.06, large: 0.08 };
  const PLACES = { top: 0.1, middle: 0.5, bottom: 0.88 };
  const FADE = 0.25;

  // A new caption at `time`, three seconds long and kept inside the clip.
  const add = (captions, time, clip) => [...(captions || []), { start: Math.max(clip.start, time), end: Math.min(clip.end, time + 3), text: 'Your text', position: 'bottom', size: 'medium' }]
    .sort((a, b) => a.start - b.start);

  // The captions showing at `time`, each with how opaque it is (0 to 1) as it fades in and out.
  const at = (captions, time) => (captions || []).filter((c) => c.text && time >= c.start && time <= c.end).map((c) => {
    const ramp = Math.min(FADE, (c.end - c.start) / 3);
    return { caption: c, alpha: ramp > 0 ? Math.min(1, (time - c.start) / ramp, (c.end - time) / ramp) : 1 };
  });

  // Font size and the point the pill is centred on, in a video area `width` × `height`.
  const layout = (caption, width, height) => ({
    fontSize: Math.round(Math.max(12, Math.min(width, height) * (SIZES[caption.size] || SIZES.medium))),
    x: width / 2,
    y: height * (PLACES[caption.position] ?? PLACES.bottom),
  });

  // Draws the captions showing at `time` into the video area at (x, y), `w` × `h`.
  function draw(ctx, captions, time, x, y, w, h, fontFamily = 'sans-serif') {
    for (const { caption, alpha } of at(captions, time)) {
      const at = layout(caption, w, h), lines = String(caption.text).split('\n').slice(0, 3);
      ctx.save();
      ctx.globalAlpha = Math.max(0, alpha);
      ctx.font = `600 ${at.fontSize}px ${fontFamily}`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      const lineHeight = at.fontSize * 1.25, textWidth = Math.min(w * 0.9, Math.max(...lines.map((l) => ctx.measureText(l).width)));
      const padX = at.fontSize * 0.8, padY = at.fontSize * 0.45, boxW = textWidth + padX * 2, boxH = lineHeight * lines.length + padY * 2;
      const cx = x + at.x, cy = Math.min(y + h - boxH / 2 - 4, Math.max(y + boxH / 2 + 4, y + at.y));
      ctx.fillStyle = 'rgba(0,0,0,.72)'; ctx.beginPath(); ctx.roundRect(cx - boxW / 2, cy - boxH / 2, boxW, boxH, Math.min(boxH / 2, at.fontSize * 0.6)); ctx.fill();
      ctx.fillStyle = '#fff';
      lines.forEach((line, i) => ctx.fillText(line, cx, cy - (lines.length - 1) * lineHeight / 2 + i * lineHeight, w * 0.9));
      ctx.restore();
    }
  }

  return { SIZES, PLACES, FADE, add, at, layout, draw };
});
