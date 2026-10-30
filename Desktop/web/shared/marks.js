// Pure helpers for the editor's marks, placed images and project files, shared by the editor and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillMarks = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const ARROW_STYLES = ['plain', 'filled', 'double', 'curved'];
  const TEXT_STYLES = ['plain', 'bold', 'outline', 'shadow', 'label', 'border', 'bubble'];
  const MAX_SIDE = 30000, MAX_PIXELS = 120000000;

  // Marks saved before styles existed have none. These two are the looks those marks were saved with, so old
  // projects render unchanged, and they stay the defaults for new marks.
  const arrowStyle = (m) => (ARROW_STYLES.includes(m.style) ? m.style : 'filled');
  const textStyle = (m) => (TEXT_STYLES.includes(m.style) ? m.style : 'shadow');

  // ---- Arrows ---------------------------------------------------------------------------------

  const isCurved = (m) => m.type === 'arrow' && m.style === 'curved';

  // The bend of a curved arrow: where it was dragged to, otherwise off to one side of the middle.
  const curveControl = (m) => (m.cx !== undefined ? { x: m.cx, y: m.cy }
    : { x: (m.x1 + m.x2) / 2 + (m.y2 - m.y1) * 0.3, y: (m.y1 + m.y2) / 2 - (m.x2 - m.x1) * 0.3 });

  // The points along a line or arrow; a curve is walked in short straight steps.
  const pathPoints = (m) => {
    const a = { x: m.x1, y: m.y1 }, b = { x: m.x2, y: m.y2 };
    if (!isCurved(m)) return [a, b];
    const c = curveControl(m), points = [];
    for (let i = 0; i <= 24; i++) {
      const t = i / 24, u = 1 - t;
      points.push({ x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y });
    }
    return points;
  };

  const pointToSegment = (p, a, b) => {
    const dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy || 1;
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len));
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
  };

  const distanceToPath = (p, m) => {
    const points = pathPoints(m);
    let best = Infinity;
    for (let i = 1; i < points.length; i++) best = Math.min(best, pointToSegment(p, points[i - 1], points[i]));
    return best;
  };

  const pathBounds = (m) => {
    const points = pathPoints(m), xs = points.map((q) => q.x), ys = points.map((q) => q.y);
    return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  };

  // What to draw for an arrow: the shaft (with a bend when curved) and its heads. A filled head is closed and the
  // shaft stops inside it; the other styles use open heads, as the Mac app does.
  const arrowShape = (m) => {
    const style = arrowStyle(m), size = Math.max(14, m.stroke * 4.2), spread = 0.45;
    const start = { x: m.x1, y: m.y1 }, tip = { x: m.x2, y: m.y2 };
    const control = isCurved(m) ? curveControl(m) : null, from = control || start;
    const angle = Math.atan2(tip.y - from.y, tip.x - from.x);
    const head = (at, direction) => ({
      tip: at, closed: style === 'filled',
      left: { x: at.x - direction * size * Math.cos(angle - spread), y: at.y - direction * size * Math.sin(angle - spread) },
      right: { x: at.x - direction * size * Math.cos(angle + spread), y: at.y - direction * size * Math.sin(angle + spread) }
    });
    const back = style === 'filled' ? Math.min(Math.hypot(tip.x - start.x, tip.y - start.y), size * 0.75) : 0;
    const end = { x: tip.x - back * Math.cos(angle), y: tip.y - back * Math.sin(angle) };
    return { start, end, control, heads: style === 'double' ? [head(tip, 1), head(start, -1)] : [head(tip, 1)] };
  };

  // ---- Text -----------------------------------------------------------------------------------

  const textWeight = (m) => (textStyle(m) === 'plain' ? 400 : 600);
  const textFont = (m, family) => `${textWeight(m)} ${m.size}px ${family}`;

  // Dark ink on light colours, white on everything else.
  const inkOn = (color) => {
    const hex = /^#?([0-9a-f]{6})$/i.exec(color || '');
    if (!hex) return '#FFFFFF';
    const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16));
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 ? '#1D1D1F' : '#FFFFFF';
  };
  // Label and bubble put the text on the mark's colour; outline fills it and strokes with the mark's colour.
  const textInk = (m) => (['label', 'bubble', 'outline'].includes(textStyle(m)) ? inkOn(m.color) : m.color);

  // Where the text and any box around it go. `width` is the measured width of the longest line. Padding follows the
  // text size so a label looks the same on a 4K capture as on a small one.
  const textLayout = (m, width) => {
    const style = textStyle(m), height = m.text.split('\n').length * m.size * 1.2;
    const text = { x: m.x, y: m.y, w: width, h: height };
    if (!['label', 'border', 'bubble'].includes(style)) {
      const grow = style === 'outline' ? m.size * 0.04 : 0;
      return { text, box: null, tail: null, bounds: { x: m.x - grow, y: m.y - grow, w: width + grow * 2, h: height + grow * 2 } };
    }
    const px = m.size * 0.32, py = m.size * 0.2;
    const box = { x: m.x - px, y: m.y - py, w: width + px * 2, h: height + py * 2, radius: m.size * 0.2 };
    const bottom = box.y + box.h, reach = style === 'bubble' ? m.size * 0.48 : 0;
    const tail = style === 'bubble' ? [{ x: box.x + m.size * 0.48, y: bottom }, { x: box.x + m.size * 0.48, y: bottom + reach }, { x: box.x + m.size * 1.08, y: bottom }] : null;
    return { text, box, tail, bounds: { x: box.x, y: box.y, w: box.w, h: box.h + reach } };
  };

  // ---- Resize, rotate and flip ----------------------------------------------------------------

  // Output size and canvas transform (a, b, c, d, e, f) that draw an image of `size` rotated or flipped.
  const orient = (size, kind) => {
    const { w, h } = size;
    switch (kind) {
      case 'cw': return { w: h, h: w, matrix: [0, 1, -1, 0, h, 0] };
      case 'ccw': return { w: h, h: w, matrix: [0, -1, 1, 0, 0, w] };
      case 'flip-h': return { w, h, matrix: [-1, 0, 0, 1, w, 0] };
      case 'flip-v': return { w, h, matrix: [1, 0, 0, -1, 0, h] };
      default: throw new Error(`Unknown orientation ${kind}`);
    }
  };

  // The other side when one changes with the aspect ratio locked.
  const linkedSide = (value, from, to) => Math.max(1, Math.round((value * to) / from));

  // Why a size can't be used, or null when it can. The limits are the Mac app's.
  const resizeProblem = (w, h) => {
    if (!Number.isInteger(w) || !Number.isInteger(h) || w < 1 || h < 1) return 'Enter a width and height in whole pixels.';
    if (w > MAX_SIDE || h > MAX_SIDE) return `Each side can be at most ${MAX_SIDE} pixels.`;
    if (w * h > MAX_PIXELS) return 'That size is too large to edit.';
    return null;
  };

  // ---- Placed images --------------------------------------------------------------------------

  // Where a dropped image goes: at most 65% of the canvas, centred on `at` (or the canvas) and kept inside it.
  const placeImage = (image, canvas, at) => {
    const scale = Math.min(1, (canvas.w / image.w) * 0.65, (canvas.h / image.h) * 0.65);
    const w = Math.max(1, Math.round(image.w * scale)), h = Math.max(1, Math.round(image.h * scale));
    const centre = at || { x: canvas.x + canvas.w / 2, y: canvas.y + canvas.h / 2 };
    const clamp = (value, low, high) => Math.round(Math.min(Math.max(low, value), high));
    return { x: clamp(centre.x - w / 2, canvas.x, canvas.x + canvas.w - w), y: clamp(centre.y - h / 2, canvas.y, canvas.y + canvas.h - h), w, h };
  };

  // The dropped files that can be placed. Still's own temp folder is skipped so dragging the capture out with
  // "Drag to share" and letting go over the editor doesn't paste it into itself.
  const droppedImages = (paths) => (paths || []).filter((p) => /\.(png|jpe?g|gif|webp|bmp)$/i.test(p) && !/[\\/]still-tmp[\\/]/.test(p));

  // Drop positions are physical pixels on Windows, but logical ones on Linux and macOS.
  const dropPoint = (position, scale, platform) => {
    const factor = platform === 'win32' ? scale || 1 : 1;
    return { clientX: position.x / factor, clientY: position.y / factor };
  };

  // ---- Assets and project files ---------------------------------------------------------------

  // Image data lives beside the document, not in it: undo states stay small however large the images are.
  const addAsset = (assets, dataUrl) => {
    const known = Object.keys(assets).find((id) => assets[id] === dataUrl);
    if (known) return known;
    let n = 1;
    while (assets[`a${n}`]) n++;
    assets[`a${n}`] = dataUrl;
    return `a${n}`;
  };

  const usedAssets = (doc) => {
    const used = new Set(doc.source ? [doc.source] : []);
    for (const m of doc.marks || []) if (m.type === 'image') used.add(m.asset);
    return used;
  };

  // The assets no state mentions, given states as JSON strings (the undo stack's form).
  const unusedAssets = (assets, states) => Object.keys(assets).filter((id) => !states.some((state) => state.includes(`"${id}"`)));

  // What goes in project.json. Version 1 had no `source` or `assets`.
  const projectFile = (doc, assets) => {
    const kept = {};
    for (const id of usedAssets(doc)) if (assets[id]) kept[id] = assets[id];
    return { version: 2, ...doc, assets: kept };
  };

  const openProject = (project, defaults) => {
    const { version, assets, ...saved } = project || {};
    return { doc: { ...defaults, ...saved, bg: { ...defaults.bg, ...(saved.bg || {}) } }, assets: { ...(assets || {}) } };
  };

  return {
    ARROW_STYLES, TEXT_STYLES, arrowStyle, textStyle, isCurved, curveControl, pathPoints, distanceToPath, pathBounds, arrowShape,
    textWeight, textFont, inkOn, textInk, textLayout, orient, linkedSide, resizeProblem, placeImage, droppedImages, dropPoint,
    addAsset, usedAssets, unusedAssets, projectFile, openProject
  };
});
