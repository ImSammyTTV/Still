// Save for Size: a picture made to a shape, a width and a file size, such as a square profile picture under 500 KB.
// The Mac app's ExportSize follows the same rules, and the tests check the same cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillFitSize = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const MAX_SIDE = 8000;

  // The part of the picture kept (all of it, or the largest square in its middle) and the size it comes out at.
  // `width` is the width wanted; empty or 0 keeps the kept part's own width. The height follows the shape.
  function plan(source, { square = false, width = 0 } = {}) {
    const side = Math.min(source.w, source.h);
    const crop = square ? { x: Math.floor((source.w - side) / 2), y: Math.floor((source.h - side) / 2), w: side, h: side } : { x: 0, y: 0, w: source.w, h: source.h };
    const w = Math.max(1, Math.min(MAX_SIDE, Math.round(width > 0 ? width : crop.w)));
    const h = Math.max(1, Math.min(MAX_SIDE, Math.round(w * crop.h / crop.w)));
    return { crop, w, h };
  }

  // Finds the best picture under `limit` bytes. `encode(scale, quality)` makes the picture at that fraction of the
  // planned size (quality 0–1, ignored for PNG) and resolves to its byte count. JPEG: the highest quality from 0.92
  // down to 0.5 that fits; if even 0.5 is too big, the picture gets smaller and the search runs again. PNG has no
  // quality, so only the size goes down. Gives up at a tenth of the size and returns the smallest it made, with
  // `fits` false. No limit: the planned size at 0.92.
  async function fit(encode, { limit = 0, jpeg = true } = {}) {
    const top = 0.92, floor = 0.5;
    if (!(limit > 0)) return { scale: 1, quality: top, bytes: await encode(1, top), fits: true };
    let scale = 1, best = null;
    for (let round = 0; round < 10 && scale >= 0.1; round++) {
      if (!jpeg) {
        const bytes = await encode(scale, 1);
        if (bytes <= limit) return { scale, quality: 1, bytes, fits: true };
        best = { scale, quality: 1, bytes, fits: false };
        scale = shrink(scale, bytes, limit);
        continue;
      }
      const atTop = await encode(scale, top);
      if (atTop <= limit) return { scale, quality: top, bytes: atTop, fits: true };
      const atFloor = await encode(scale, floor);
      if (atFloor <= limit) {
        // Between the two: halve the gap six times, keeping the best quality that fits.
        let lo = floor, hi = top, found = { scale, quality: floor, bytes: atFloor, fits: true };
        for (let i = 0; i < 6; i++) {
          const q = (lo + hi) / 2, bytes = await encode(scale, q);
          if (bytes <= limit) { lo = q; found = { scale, quality: q, bytes, fits: true }; } else hi = q;
        }
        return found;
      }
      best = { scale, quality: floor, bytes: atFloor, fits: false };
      scale = shrink(scale, atFloor, limit);
    }
    return best;
  }
  // File size goes roughly with the number of pixels, so the sides shrink by the square root, and a little more.
  const shrink = (scale, bytes, limit) => scale * Math.max(0.5, Math.min(0.9, Math.sqrt(limit / bytes) * 0.95));

  const kb = (bytes) => bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return { plan, fit, kb, MAX_SIDE };
});
