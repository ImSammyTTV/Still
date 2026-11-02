// Sizes for social media: picking one in the crop tool locks the crop to its shape, and applying it scales the picture
// to exactly that many pixels. A size can name a safe area, the middle part every device shows (a YouTube banner is
// cut down to a strip on phones). The Mac app's SocialSizes follows the same list and rules, and shares the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillSizes = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const SIZES = [
    { id: 'yt-thumb', group: 'YouTube', name: 'Thumbnail', w: 1280, h: 720 },
    { id: 'yt-banner', group: 'YouTube', name: 'Channel Banner', w: 2560, h: 1440, safe: { w: 1546, h: 423 } },
    { id: 'ig-square', group: 'Instagram', name: 'Square Post', w: 1080, h: 1080 },
    { id: 'ig-portrait', group: 'Instagram', name: 'Portrait Post', w: 1080, h: 1350 },
    { id: 'ig-story', group: 'Instagram', name: 'Story or Reel', w: 1080, h: 1920 },
    { id: 'tiktok', group: 'TikTok', name: 'Video Cover', w: 1080, h: 1920 },
    { id: 'x-post', group: 'X', name: 'Post', w: 1600, h: 900 },
    { id: 'x-header', group: 'X', name: 'Header', w: 1500, h: 500 },
    { id: 'fb-post', group: 'Facebook', name: 'Link Post', w: 1200, h: 630 },
    { id: 'fb-cover', group: 'Facebook', name: 'Cover', w: 851, h: 315 },
    { id: 'li-post', group: 'LinkedIn', name: 'Post', w: 1200, h: 627 },
    { id: 'li-banner', group: 'LinkedIn', name: 'Banner', w: 1584, h: 396 },
    { id: 'twitch', group: 'Twitch', name: 'Profile Banner', w: 1200, h: 480 },
    { id: 'discord', group: 'Discord', name: 'Server Banner', w: 960, h: 540 },
    { id: 'pinterest', group: 'Pinterest', name: 'Pin', w: 1000, h: 1500 },
  ];
  const byId = (id) => SIZES.find((s) => s.id === id) || null;
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

  // The largest rectangle of this shape (width / height) that fits `bounds`, in its middle.
  function centered(bounds, aspect) {
    let w = bounds.w, h = w / aspect;
    if (h > bounds.h) { h = bounds.h; w = h * aspect; }
    return { x: (bounds.x || 0) + (bounds.w - w) / 2, y: (bounds.y || 0) + (bounds.h - h) / 2, w, h };
  }
  // A rectangle of this shape dragged from `from` towards `to`. Its far corner follows the pointer along the shape's
  // diagonal (the nearest point on it), so moving either way grows or shrinks it, and it never goes past `bounds`.
  function dragged(from, to, aspect, bounds) {
    const sx = to.x >= from.x ? 1 : -1, sy = to.y >= from.y ? 1 : -1;
    const roomX = sx > 0 ? bounds.x + bounds.w - from.x : from.x - bounds.x, roomY = sy > 0 ? bounds.y + bounds.h - from.y : from.y - bounds.y;
    let w = aspect * (Math.abs(to.x - from.x) * aspect + Math.abs(to.y - from.y)) / (aspect * aspect + 1);
    w = Math.min(w, roomX, roomY * aspect);
    const h = w / aspect;
    return { x: sx > 0 ? from.x : from.x - w, y: sy > 0 ? from.y : from.y - h, w, h };
  }
  // One corner dragged to `to` while the opposite corner stays put, keeping the shape.
  function cornered(rect, corner, to, aspect, bounds) {
    const fixed = { x: corner.includes('w') ? rect.x + rect.w : rect.x, y: corner.includes('n') ? rect.y + rect.h : rect.y };
    return dragged(fixed, to, aspect, bounds);
  }
  // Where a size's safe area falls inside a crop of its shape.
  function safeArea(crop, size) {
    if (!size || !size.safe) return null;
    const w = crop.w * size.safe.w / size.w, h = crop.h * size.safe.h / size.h;
    return { x: crop.x + (crop.w - w) / 2, y: crop.y + (crop.h - h) / 2, w, h };
  }
  // A short note for the crop bar: the size the picture comes out at, and whether it has to grow to get there.
  function note(crop, size) {
    if (!size || !crop) return '';
    const grows = crop.w + 0.5 < size.w;
    return `${size.w} × ${size.h}${grows ? ' · enlarged, may look soft' : ''}`;
  }
  return { SIZES, byId, centered, dragged, cornered, safeArea, note, clamp };
});
