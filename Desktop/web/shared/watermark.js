// The watermark: a line of your own text (a name, a handle, "Draft") or a picture of your own (a logo) laid over
// every picture the editor copies, saves or shares. It's sized from the picture's shorter side, so it reads the same on a small crop and a full
// screen. The Mac app's Watermark follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillWatermark = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const POSITIONS = ['bottomRight', 'bottomLeft', 'topRight', 'topLeft', 'center'];
  const SIZES = { small: 0.022, medium: 0.032, large: 0.048 };
  // An image watermark fits a square this share of the picture's shorter side.
  const IMAGE_SIZES = { small: 0.12, medium: 0.18, large: 0.26 };

  // The saved setting, tidied: kind "image" needs a picture, otherwise no text means no watermark.
  function normalize(wm) {
    const image = wm && wm.kind === 'image' ? String(wm.image || '') : '';
    const text = String((wm && wm.text) || '').trim().slice(0, 120);
    if (wm && wm.kind === 'image' ? !image : !text) return null;
    return {
      kind: image ? 'image' : 'text', image, text,
      position: POSITIONS.includes(wm.position) ? wm.position : 'bottomRight',
      size: SIZES[wm.size] ? wm.size : 'medium',
      opacity: Math.min(1, Math.max(0.1, Number(wm.opacity) || 0.7)),
    };
  }

  // Font size and the point the text hangs from, with how it hangs (0 = left/top, 0.5 = middle, 1 = right/bottom).
  function placement(width, height, wm) {
    const fontSize = Math.round(Math.min(96, Math.max(11, Math.min(width, height) * SIZES[wm.size])));
    const margin = Math.round(fontSize * 0.9);
    const p = wm.position;
    const alignX = p === 'center' ? 0.5 : p.endsWith('Right') ? 1 : 0;
    const alignY = p === 'center' ? 0.5 : p.startsWith('bottom') ? 1 : 0;
    const x = alignX === 0.5 ? width / 2 : alignX ? width - margin : margin;
    const y = alignY === 0.5 ? height / 2 : alignY ? height - margin : margin;
    return { fontSize, margin, x, y, alignX, alignY };
  }

  // Where an image watermark goes, from the top left: it fits a square sized from the picture's shorter side, keeps
  // its shape, and sits in the chosen corner (or the middle) a small margin from the edges.
  function imageFrame(width, height, imageWidth, imageHeight, wm) {
    const side = Math.min(width, height), box = Math.max(16, side * IMAGE_SIZES[wm.size]);
    const scale = Math.min(box / imageWidth, box / imageHeight);
    const w = Math.max(1, Math.round(imageWidth * scale)), h = Math.max(1, Math.round(imageHeight * scale));
    const margin = Math.round(Math.max(8, side * 0.03)), p = wm.position;
    const x = p === 'center' ? Math.round((width - w) / 2) : p.endsWith('Right') ? width - margin - w : margin;
    const y = p === 'center' ? Math.round((height - h) / 2) : p.startsWith('bottom') ? height - margin - h : margin;
    return { x, y, w, h };
  }

  // White text with a soft dark shadow, so it reads on light and dark pictures alike. An image watermark is drawn
  // from `picture`, the loaded image (nothing is drawn until it has loaded).
  function draw(ctx, width, height, setting, fontFamily = 'sans-serif', picture = null) {
    const wm = normalize(setting);
    if (!wm) return;
    if (wm.kind === 'image') {
      if (!picture || !(picture.naturalWidth || picture.width)) return;
      const f = imageFrame(width, height, picture.naturalWidth || picture.width, picture.naturalHeight || picture.height, wm);
      ctx.save(); ctx.globalAlpha = wm.opacity; ctx.imageSmoothingQuality = 'high'; ctx.drawImage(picture, f.x, f.y, f.w, f.h); ctx.restore();
      return;
    }
    const at = placement(width, height, wm);
    ctx.save();
    ctx.globalAlpha = wm.opacity;
    ctx.font = `600 ${at.fontSize}px ${fontFamily}`;
    ctx.textAlign = ['left', 'center', 'right'][at.alignX * 2];
    ctx.textBaseline = ['top', 'middle', 'bottom'][at.alignY * 2];
    ctx.shadowColor = 'rgba(0,0,0,.55)'; ctx.shadowBlur = at.fontSize / 4; ctx.shadowOffsetY = at.fontSize / 16;
    ctx.fillStyle = '#fff';
    ctx.fillText(wm.text, at.x, at.y);
    ctx.restore();
  }

  return { POSITIONS, SIZES, IMAGE_SIZES, normalize, placement, imageFrame, draw };
});
