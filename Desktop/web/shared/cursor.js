// The pointer, drawn by the video editor from the path Still noted while recording, for recordings made with the
// pointer left out of the picture. Shared by the page and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillCursor = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const SMOOTHING = 0.12; // Seconds of path averaged, behind and ahead, for smooth movement.

  // Where the path puts the pointer at `time`: between two notes it moves in a straight line, and before the first
  // or after the last it waits there. Null without a path.
  function raw(pointer, time) {
    if (!pointer || !pointer.length) return null;
    if (time <= pointer[0][0]) return { x: pointer[0][1], y: pointer[0][2] };
    let low = 0, high = pointer.length - 1;
    if (time >= pointer[high][0]) return { x: pointer[high][1], y: pointer[high][2] };
    while (high - low > 1) { const mid = (low + high) >> 1; if (pointer[mid][0] <= time) low = mid; else high = mid; }
    const [t0, x0, y0] = pointer[low], [t1, x1, y1] = pointer[high];
    const k = t1 > t0 ? (time - t0) / (t1 - t0) : 0;
    return { x: x0 + (x1 - x0) * k, y: y0 + (y1 - y0) * k };
  }

  // The same, averaged over a short stretch so hand jitter and the steps between notes melt away.
  function at(pointer, time, smooth) {
    if (!smooth) return raw(pointer, time);
    const steps = 6, points = [];
    for (let i = 0; i <= steps; i++) { const p = raw(pointer, time - SMOOTHING + (2 * SMOOTHING * i) / steps); if (p) points.push(p); }
    if (!points.length) return null;
    return { x: points.reduce((sum, p) => sum + p.x, 0) / points.length, y: points.reduce((sum, p) => sum + p.y, 0) / points.length };
  }

  // A standard arrow pointer with its tip at (x, y), `size` pixels tall: white with a dark edge, so it reads on
  // light and dark pages alike.
  function draw(ctx, x, y, size) {
    const s = size / 22;
    const outline = [[0, 0], [0, 17], [4.5, 13], [7.5, 20], [10.5, 18.8], [7.6, 12], [13.5, 12]];
    ctx.save();
    ctx.translate(x, y); ctx.scale(s, s);
    ctx.beginPath(); outline.forEach(([px, py], i) => (i ? ctx.lineTo(px, py) : ctx.moveTo(px, py))); ctx.closePath();
    ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = 2.5; ctx.shadowOffsetY = 1;
    ctx.fillStyle = '#fff'; ctx.fill();
    ctx.shadowColor = 'transparent'; ctx.lineJoin = 'round'; ctx.lineWidth = 1.3; ctx.strokeStyle = '#111'; ctx.stroke();
    ctx.restore();
  }

  // The Mac's Dot style: a soft white disc centred on the point, `size` across, that shows where the pointer is
  // without covering what's under it.
  function dot(ctx, x, y, size) {
    ctx.save();
    ctx.beginPath(); ctx.arc(x, y, size / 2, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255,255,255,.4)'; ctx.fill();
    ctx.lineWidth = Math.max(1, size / 24); ctx.strokeStyle = 'rgba(0,0,0,.25)'; ctx.stroke();
    ctx.restore();
  }

  return { SMOOTHING, raw, at, draw, dot };
});
