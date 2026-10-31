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

  // Maps a rectangle in display points to image pixels.
  const toPixels = (r, scale) => ({
    x: Math.round(r.x * scale), y: Math.round(r.y * scale),
    w: Math.max(1, Math.round(r.w * scale)), h: Math.max(1, Math.round(r.h * scale))
  });

  // Windows are listed front to back; the first one under the pointer wins.
  const windowAt = (windows, point) => windows.find((w) => contains(w, point)) || null;

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

  return { DEFAULT_NAME, fileName, hexColor, rememberColor, inkOn, videoBitrate, normalize, intersect, contains, dragRect, nudge, toPixels, windowAt, fit, canvasSize, formatDuration, captureName, shortcutLabel };
});
