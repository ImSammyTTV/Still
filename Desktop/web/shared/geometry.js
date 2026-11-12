// Pure helpers shared by the main process, the renderers and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillGeometry = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const normalize = (r) => ({
    x: Math.min(r.x, r.x + r.w), y: Math.min(r.y, r.y + r.h),
    w: Math.abs(r.w), h: Math.abs(r.h)
  });

  const intersect = (a, b) => {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const w = Math.min(a.x + a.w, b.x + b.w) - x, h = Math.min(a.y + a.h, b.y + b.h) - y;
    return w > 0 && h > 0 ? { x, y, w, h } : { x, y, w: 0, h: 0 };
  };

  const contains = (r, p) => p.x >= r.x && p.y >= r.y && p.x <= r.x + r.w && p.y <= r.y + r.h;

  // Builds a selection from a drag, honouring a fixed aspect ratio (w / h) or Shift for a square.
  const dragRect = (anchor, point, { aspect = 0, square = false, bounds } = {}) => {
    const dx = point.x - anchor.x, dy = point.y - anchor.y;
    let w = Math.abs(dx), h = Math.abs(dy);
    if (square) h = w;
    else if (aspect > 0) h = w / aspect;
    const rect = { x: dx >= 0 ? anchor.x : anchor.x - w, y: dy >= 0 ? anchor.y : anchor.y - h, w, h };
    return bounds ? intersect(rect, bounds) : rect;
  };

  // Arrow keys move the selection; with resize they grow it from the bottom-right corner.
  const nudge = (r, dx, dy, { resize = false, bounds } = {}) => {
    let next = resize ? { ...r, w: Math.max(1, r.w + dx), h: Math.max(1, r.h + dy) } : { ...r, x: r.x + dx, y: r.y + dy };
    if (bounds) {
      next.w = Math.min(next.w, bounds.w); next.h = Math.min(next.h, bounds.h);
      next.x = Math.min(Math.max(bounds.x, next.x), bounds.x + bounds.w - next.w);
      next.y = Math.min(Math.max(bounds.y, next.y), bounds.y + bounds.h - next.h);
    }
    return next;
  };

  // Space held mid-drag moves the selection: how far it can go towards (dx, dy) without leaving `bounds`.
  const moveWithin = (r, dx, dy, bounds) => ({
    dx: Math.min(Math.max(dx, bounds.x - r.x), bounds.x + bounds.w - (r.x + r.w)),
    dy: Math.min(Math.max(dy, bounds.y - r.y), bounds.y + bounds.h - (r.y + r.h))
  });

  // Adjusting a finished selection before it's captured. Which part of it is under the pointer: an edge or corner
  // ('n', 'se', …) within `tolerance` of it, 'inside', or null. Corners win over edges, edges over the inside, so a
  // small selection can still be resized.
  const handleAt = (r, p, tolerance = 7) => {
    if (!r || r.w <= 0 || r.h <= 0) return null;
    const near = (a, b) => Math.abs(a - b) <= tolerance;
    const inX = p.x >= r.x - tolerance && p.x <= r.x + r.w + tolerance, inY = p.y >= r.y - tolerance && p.y <= r.y + r.h + tolerance;
    if (!inX || !inY) return null;
    const v = near(p.y, r.y) ? 'n' : near(p.y, r.y + r.h) ? 's' : '';
    const h = near(p.x, r.x) ? 'w' : near(p.x, r.x + r.w) ? 'e' : '';
    if (v || h) return v + h;
    return contains(r, p) ? 'inside' : null;
  };
  // The selection with one edge or corner dragged by (dx, dy) from where it was when the drag began, never smaller
  // than `min`, inside `bounds`, and keeping `aspect` (width / height) when one is set.
  const resizeRect = (start, handle, dx, dy, { bounds, aspect = 0, min = 4 } = {}) => {
    let x0 = start.x, y0 = start.y, x1 = start.x + start.w, y1 = start.y + start.h;
    if (handle.includes('w')) x0 = Math.min(x1 - min, x0 + dx);
    if (handle.includes('e')) x1 = Math.max(x0 + min, x1 + dx);
    if (handle.includes('n')) y0 = Math.min(y1 - min, y0 + dy);
    if (handle.includes('s')) y1 = Math.max(y0 + min, y1 + dy);
    if (bounds) { x0 = Math.max(bounds.x, x0); y0 = Math.max(bounds.y, y0); x1 = Math.min(bounds.x + bounds.w, x1); y1 = Math.min(bounds.y + bounds.h, y1); }
    let r = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    if (aspect > 0) {
      // Width leads unless only the top or bottom edge moved; the opposite side stays put.
      if (handle === 'n' || handle === 's') r.w = r.h * aspect; else r.h = r.w / aspect;
      if (handle.includes('w')) r.x = x1 - r.w;
      if (handle.includes('n')) r.y = y1 - r.h;
      if (bounds) r = intersect(r, bounds);
    }
    return r;
  };

  // Maps a rectangle in display points to image pixels.
  const toPixels = (r, scale) => ({
    x: Math.round(r.x * scale), y: Math.round(r.y * scale),
    w: Math.max(1, Math.round(r.w * scale)), h: Math.max(1, Math.round(r.h * scale))
  });

  // Windows are listed front to back; the first one under the pointer wins.
  const windowAt = (windows, point) => windows.find((w) => contains(w, point)) || null;
  // Parts of a window found from its picture, for when the system can't say what's inside it: the long straight
  // lines across the whole window near its top, where a title bar, tab strip or toolbar ends and the page begins.
  // `lum(x, y)` gives the brightness (0–255) of the window's pixel; w and h are its size in those pixels. Returns
  // one part per line found, each the window below that line, largest first (so the wheel steps down a band at a
  // time). The same rule is in StillCore's WindowParts.swift.
  const bandParts = (lum, w, h) => {
    if (w < 120 || h < 120) return [];
    const step = Math.max(1, Math.floor(w / 400)), cols = [];
    for (let x = Math.floor(w * 0.02); x < w * 0.98; x += step) cols.push(x);
    const lines = [];
    for (let y = 4; y < h * 0.45; y++) {
      let edges = 0;
      for (const x of cols) if (Math.abs(lum(x, y) - lum(x, y - 1)) > 18) edges++;
      if (edges >= cols.length * 0.9 && (!lines.length || y - lines[lines.length - 1] > 6)) lines.push(y);
      if (lines.length === 4) break;
    }
    return lines.filter((y) => h - y >= h * 0.4).map((y) => ({ x: 0, y, w, h: h - y }));
  };
  // In window selection the wheel steps from the whole window into the parts of it under the pointer (a browser's
  // page without its tabs and toolbar, a pane) and back out. Depth 0 is the whole window; each step goes one part
  // smaller. Returns what is selected at that depth and how deep it can go here.
  const windowPartAt = (win, point, depth) => {
    if (!win) return { rect: null, depth: 0, deepest: 0 };
    const under = (win.parts || []).filter((p) => contains(p, point)).sort((a, b) => b.w * b.h - a.w * a.h);
    const d = Math.max(0, Math.min(depth, under.length));
    return { rect: d === 0 ? win : under[d - 1], depth: d, deepest: under.length };
  };

  // Fits content of size into a box, never upscaling beyond 1.
  const fit = (size, box) => {
    const scale = Math.min(1, box.w / size.w, box.h / size.h);
    return { w: size.w * scale, h: size.h * scale, scale };
  };

  // Output size of an image placed on a background with padding and an optional aspect ratio.
  const canvasSize = (image, { padding = 0, aspect = 0 } = {}) => {
    let w = image.w + padding * 2, h = image.h + padding * 2;
    if (aspect > 0) { if (w / h > aspect) h = Math.round(w / aspect); else w = Math.round(h * aspect); }
    return { w: Math.round(w), h: Math.round(h) };
  };

  const formatDuration = (seconds) => {
    const s = Math.max(0, Math.floor(seconds));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  };

  // "Still 2026-10-25 at 15.04.12" — sortable and safe for every file system.
  const captureName = (date = new Date(), kind = 'Still') => {
    const p = (n) => String(n).padStart(2, '0');
    return `${kind} ${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())} at ${p(date.getHours())}.${p(date.getMinutes())}.${p(date.getSeconds())}`;
  };

  // Turns an accelerator such as "CommandOrControl+Shift+4" into a readable label.
  const shortcutLabel = (accelerator, platform = 'win32') => {
    if (!accelerator) return '';
    return accelerator.split('+').map((part) => ({
      CommandOrControl: platform === 'darwin' ? '⌘' : 'Ctrl', CmdOrCtrl: platform === 'darwin' ? '⌘' : 'Ctrl',
      Control: 'Ctrl', Alt: 'Alt', Shift: 'Shift', Super: platform === 'win32' ? 'Win' : 'Super', Meta: 'Super',
      PrintScreen: 'PrtSc', Space: 'Space'
    }[part] || part)).join(' + ');
  };

  // The Mac app's recording qualities in bits per pixel per frame, as Still's own recorder on Windows uses them.
  const videoBitrate = (width, height, fps, quality) => {
    // A bitrate chosen in Settings, as the Mac stores it: "bitrate:12000000", 1 to 100 Mbit/s.
    const chosen = /^bitrate:(\d+)$/.exec(String(quality || ''));
    if (chosen && Number(chosen[1]) > 0) return Math.min(100_000_000, Math.max(1_000_000, Number(chosen[1])));
    const factor = quality === 'compact' ? 0.045 : quality === 'balanced' ? 0.09 : 0.18;
    return Math.round(Math.min(100_000_000, Math.max(400_000, width * height * Math.max(1, fps) * factor)));
  };

  // An exported video's size: the shorter side brought down to `limit` (1080 for "1080p"), never up, and both
  // sides even, as video encoders need. A limit of 0 keeps the size as it is. The Mac app's export uses the same rule.
  const exportSize = (width, height, limit) => {
    const k = limit > 0 ? Math.min(1, limit / Math.max(1, Math.min(width, height))) : 1;
    return { width: Math.max(2, Math.floor(width * k / 2) * 2), height: Math.max(2, Math.floor(height * k / 2) * 2) };
  };
  // Roughly how big a video comes out, in bytes, from its bitrate and length, with a little for the sound.
  const estimateBytes = (bitrate, seconds) => Math.round((bitrate + 128_000) * Math.max(0, seconds) / 8);
  const sizeLabel = (bytes) => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${Math.max(1, Math.round(bytes / 1e6))} MB` : `${Math.max(1, Math.round(bytes / 1e3))} KB`;

  // A colour as #RRGGBB, and the recent colours list it joins: newest first, no repeats, at most `max`.
  const hexColor = (r, g, b) => '#' + [r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('').toUpperCase();
  const rememberColor = (list, color, max = 10) => [color, ...(Array.isArray(list) ? list : []).filter((c) => typeof c === 'string' && c.toUpperCase() !== color.toUpperCase())].slice(0, max);
  // Black or white, whichever reads better on the colour.
  const inkOn = (hex) => { const n = parseInt(hex.slice(1), 16); return (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) > 150 ? '#000000' : '#FFFFFF'; };

  // The name a new capture gets from Settings → Screenshots → File name. The app names files with the same rule
  // (library.rs `name_from`); this copy shows the preview while you type.
  const DEFAULT_NAME = '{type} {date} at {time}';
  const fileName = (pattern, { date = new Date(), kind = 'screenshot', width = 0, height = 0, n = 1 } = {}) => {
    const two = (v) => String(v).padStart(2, '0');
    const fill = (p) => p.split('{date}').join(`${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())}`)
      .split('{time}').join(`${two(date.getHours())}.${two(date.getMinutes())}.${two(date.getSeconds())}`)
      .split('{type}').join(kind === 'recording' ? 'Recording' : 'Screenshot')
      .split('{width}').join(width > 0 ? String(width) : '').split('{height}').join(height > 0 ? String(height) : '')
      .split('{n}').join(String(n));
    const clean = (s) => s.replace(/[\\/:*?"<>|\n\r\t]/g, '-').split(/\s+/).filter(Boolean).join(' ');
    const name = [...clean(fill(String(pattern || '')))].slice(0, 180).join('');
    return name.replace(/^[-. ]+|[-. ]+$/g, '') ? name : clean(fill(DEFAULT_NAME));
  };

  // The capture magnifier. Its zoom steps (screen pixels shown per screen pixel); the box grows with the zoom, so
  // zooming in shows more detail without the picture getting cramped. The same numbers are in SelectionGeometry.swift.
  const MAGNIFIER_ZOOMS = [2, 3, 4, 6, 8, 12, 16];
  const magnifierSize = (zoom) => 80 + 16 * Math.max(0, MAGNIFIER_ZOOMS.indexOf(zoom));
  // Up and to the right of the pointer, moving to the left or below wherever that side would run off the screen,
  // so the box never comes to rest under the pointer. `below` is room kept under the box for the colour chip.
  const magnifierPlace = (pointer, size, view, { gap = 24, margin = 10, below = 26 } = {}) => {
    let x = pointer.x + gap, y = pointer.y - gap - size;
    if (x + size > view.w - margin) x = pointer.x - gap - size;
    if (y < margin) y = pointer.y + gap;
    x = Math.max(margin, Math.min(view.w - size - margin, x));
    y = Math.max(margin, Math.min(view.h - size - below - margin, y));
    return { x, y };
  };

  return { MAGNIFIER_ZOOMS, magnifierSize, magnifierPlace, DEFAULT_NAME, fileName, hexColor, rememberColor, inkOn, videoBitrate, normalize, intersect, contains, dragRect, nudge, moveWithin, handleAt, resizeRect, toPixels, windowAt, windowPartAt, bandParts, fit, canvasSize, formatDuration, captureName, shortcutLabel, exportSize, estimateBytes, sizeLabel };
});
