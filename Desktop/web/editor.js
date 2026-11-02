const G = StillGeometry, M = StillMarks, S = StillSizes;
const stage = $('#stage'), ctx = stage.getContext('2d');
const scroller = $('#scroller');
const itemId = params.get('id') || null;
// The functional selection colour for handles and crop frames comes from the stylesheet.
const SELECTION = getComputedStyle(document.documentElement).getPropertyValue('--selection').trim() || '#0a84ff';

const TOOLS = [
  ['select', 'mouse-pointer-2', 'Select', 'v'], ['arrow', 'move-up-right', 'Arrow', 'a'], ['rect', 'square', 'Rectangle', 'r'],
  ['filled', 'square-dashed-bottom', 'Filled Rectangle', 'f'], ['ellipse', 'circle', 'Ellipse', 'o'], ['line', 'slash', 'Line', 'l'],
  ['pen', 'pencil', 'Pen', 'p'], ['highlight', 'highlighter', 'Highlight', 'h'], ['text', 'type', 'Text', 't'], ['step', 'list-ordered', 'Step', 'n'],
  ['redact', 'eye-off', 'Redact', 'b'], ['blur', 'droplet', 'Blur', 'u'], ['pixelate', 'grid-3x3', 'Pixelate', 'x'], ['spotlight', 'sun-dim', 'Spotlight', 's'], ['loupe', 'zoom-in', 'Loupe', 'm'], ['measure', 'ruler', 'Measure', 'd'], ['stamp', 'smile-plus', 'Stamp', 'e'], ['crop', 'crop', 'Crop', 'c']
];
const COLORS = ['#FF453A', '#FF9F0A', '#FFD60A', '#32D74B', '#64D2FF', '#0A84FF', '#BF5AF2', '#FF375F', '#FFFFFF', '#1D1D1F'];
const STROKES = [2, 4, 6, 10, 16];
// The Stamp tool's emoji; the style menu picks one, and a click drops it at a size that suits the picture.
const STAMPS = ['✅', '❌', '⚠️', '👉', '👆', '⭐', '❤️', '👍', '👎', '🔥', '💡', '❓', '👀', '🎉', '🐛', '🚫'];
const GRADIENTS = StillBackdrop.GRADIENTS;

// `image` is what's being edited: the original capture, or doc.source once it has been resized, rotated or flipped.
let image = new Image(), original = image, bgImage = null, prefs = {};
let doc = { marks: [], crop: null, source: null, bg: { style: 'none', padding: 64, radius: 12, shadow: true, aspect: 0, balance: false, custom: null } };
let tool = 'arrow', color = '#FF453A', stroke = 4, zoom = 0;
const styles = { arrow: 'filled', text: 'shadow', stamp: '✅' };
// Images the document uses, by id: their data URLs, and decoded copies because drawing has to be synchronous.
let assets = {};
const decoded = new Map();
let selected = null, drag = null, pendingCrop = null, cropSize = null, history = [], future = [], dirty = false, saveTimer = null;
const isRectLike = (m) => ['rect', 'filled', 'ellipse', 'highlight', 'redact', 'blur', 'pixelate', 'spotlight', 'loupe', 'stamp', 'image'].includes(m.type);
// How much a Loupe enlarges what's under it.
const LOUPE_ZOOM = 2;
const isSegment = (m) => m.type === 'arrow' || m.type === 'line' || m.type === 'measure';

// ---- Layout ---------------------------------------------------------------------------------

const base = () => (tool === 'crop' ? { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight } : doc.crop || { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight });
function layout(forCrop = tool === 'crop') {
  const b = forCrop ? { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight } : base();
  const hasBg = !forCrop && doc.bg.style !== 'none';
  const pad = hasBg ? doc.bg.padding : 0;
  const size = G.canvasSize(b, { padding: pad, aspect: hasBg ? doc.bg.aspect : 0 });
  return { base: b, hasBg, w: size.w, h: size.h, ox: (size.w - b.w) / 2, oy: (size.h - b.h) / 2 };
}

function toImage(e) {
  const r = stage.getBoundingClientRect(), L = layout();
  const sx = stage.width / r.width;
  return { x: (e.clientX - r.left) * sx - L.ox + L.base.x, y: (e.clientY - r.top) * sx - L.oy + L.base.y };
}
const displayScale = () => stage.getBoundingClientRect().width / stage.width || 1;

// ---- Rendering ------------------------------------------------------------------------------

function render(target = ctx, { handles = true } = {}) {
  const L = layout();
  const c = target.canvas;
  if (c.width !== L.w || c.height !== L.h) { c.width = L.w; c.height = L.h; if (target === ctx) fitZoom(); }
  target.save();
  target.clearRect(0, 0, L.w, L.h);
  if (L.hasBg) {
    StillBackdrop.paint(target, L, { x: L.ox, y: L.oy, w: L.base.w, h: L.base.h, radius: doc.bg.radius }, doc.bg, bgImage);
  }
  target.translate(L.ox - L.base.x, L.oy - L.base.y);
  if (L.hasBg) { target.beginPath(); target.rect(L.base.x, L.base.y, L.base.w, L.base.h); target.clip(); }
  target.drawImage(image, 0, 0);
  for (const m of doc.marks) drawMark(target, m);
  if (target === ctx && tool === 'crop') drawCropOverlay(target);
  if (handles && target === ctx && selected && tool === 'select') drawHandles(target, selected);
  target.restore();
  // The watermark from Settings sits over the whole picture, background included; the toolbar can leave it off this one.
  if (doc.watermark !== false) StillWatermark.draw(target, L.w, L.h, prefs.watermark, fontFamily());
  if (target === ctx) syncStyleButton();
}

function drawArrow(t, m) {
  const shape = M.arrowShape(m);
  t.beginPath(); t.moveTo(shape.start.x, shape.start.y);
  if (shape.control) t.quadraticCurveTo(shape.control.x, shape.control.y, shape.end.x, shape.end.y); else t.lineTo(shape.end.x, shape.end.y);
  t.stroke();
  for (const head of shape.heads) {
    t.beginPath(); t.moveTo(head.left.x, head.left.y); t.lineTo(head.tip.x, head.tip.y); t.lineTo(head.right.x, head.right.y);
    if (head.closed) { t.closePath(); t.fill(); } else t.stroke();
  }
}

const fontFamily = () => getComputedStyle(document.body).fontFamily;
function measureText(t, m) {
  t.save(); t.font = M.textFont(m, fontFamily());
  const width = Math.max(...m.text.split('\n').map((line) => t.measureText(line).width)); t.restore();
  return M.textLayout(m, Math.max(10, width));
}
function drawText(t, m) {
  const style = M.textStyle(m), { box, tail } = measureText(t, m);
  if (box) {
    t.beginPath(); t.roundRect(box.x, box.y, box.w, box.h, box.radius);
    if (style === 'border') t.stroke(); else t.fill();
    if (tail) { t.beginPath(); t.moveTo(tail[0].x, tail[0].y); t.lineTo(tail[1].x, tail[1].y); t.lineTo(tail[2].x, tail[2].y); t.closePath(); t.fill(); }
  }
  t.font = M.textFont(m, fontFamily()); t.textBaseline = 'top'; t.fillStyle = M.textInk(m);
  if (style === 'shadow') { t.shadowColor = m.color === '#1D1D1F' ? 'rgba(255,255,255,.6)' : 'rgba(0,0,0,.45)'; t.shadowBlur = Math.max(2, m.size / 10); }
  if (style === 'outline') t.lineWidth = m.size * 0.08;
  m.text.split('\n').forEach((line, i) => {
    if (style === 'outline') t.strokeText(line, m.x, m.y + i * m.size * 1.2);
    t.fillText(line, m.x, m.y + i * m.size * 1.2);
  });
}

function drawMark(t, m) {
  t.save();
  t.lineCap = 'round'; t.lineJoin = 'round'; t.strokeStyle = m.color; t.fillStyle = m.color; t.lineWidth = m.stroke;
  const r = m.w !== undefined ? G.normalize(m) : null;
  switch (m.type) {
    case 'rect': t.strokeRect(r.x, r.y, r.w, r.h); break;
    case 'filled': t.beginPath(); t.roundRect(r.x, r.y, r.w, r.h, 4); t.fill(); break;
    case 'redact': t.fillStyle = '#000'; t.fillRect(r.x, r.y, r.w, r.h); break;
    case 'ellipse': t.beginPath(); t.ellipse(r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2, 0, 0, Math.PI * 2); t.stroke(); break;
    case 'line': t.beginPath(); t.moveTo(m.x1, m.y1); t.lineTo(m.x2, m.y2); t.stroke(); break;
    case 'stamp': {
      // The emoji fills the box's shorter side, centred in it.
      const size = Math.min(r.w, r.h);
      t.font = `${Math.max(4, size * 0.86)}px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", ${fontFamily()}`;
      t.textAlign = 'center'; t.textBaseline = 'middle'; t.fillText(m.text || '✅', r.x + r.w / 2, r.y + r.h / 2 + size * 0.04);
      break;
    }
    case 'measure': {
      // A line with a short bar across each end and its length in a pill at the middle.
      const angle = Math.atan2(m.y2 - m.y1, m.x2 - m.x1), bar = Math.max(8, m.stroke * 3);
      const nx = -Math.sin(angle) * bar, ny = Math.cos(angle) * bar;
      t.beginPath(); t.moveTo(m.x1, m.y1); t.lineTo(m.x2, m.y2);
      t.moveTo(m.x1 - nx, m.y1 - ny); t.lineTo(m.x1 + nx, m.y1 + ny); t.moveTo(m.x2 - nx, m.y2 - ny); t.lineTo(m.x2 + nx, m.y2 + ny); t.stroke();
      const label = M.measureLabel(m), size = Math.max(13, m.stroke * 3.5);
      t.font = `600 ${size}px ${fontFamily()}`;
      const w = t.measureText(label).width + size, h = size * 1.7, cx = (m.x1 + m.x2) / 2, cy = (m.y1 + m.y2) / 2;
      t.fillStyle = 'rgba(0,0,0,.78)'; t.beginPath(); t.roundRect(cx - w / 2, cy - h / 2, w, h, h / 2); t.fill();
      t.fillStyle = '#fff'; t.textAlign = 'center'; t.textBaseline = 'middle'; t.fillText(label, cx, cy + 1);
      break;
    }
    case 'arrow': {
      t.shadowColor = 'rgba(0,0,0,.25)'; t.shadowBlur = 4; t.shadowOffsetY = 1;
      drawArrow(t, m); break;
    }
    case 'pen': {
      const p = m.points; if (p.length < 2) break;
      t.beginPath(); t.moveTo(p[0].x, p[0].y);
      for (let i = 1; i < p.length - 1; i++) t.quadraticCurveTo(p[i].x, p[i].y, (p[i].x + p[i + 1].x) / 2, (p[i].y + p[i + 1].y) / 2);
      t.lineTo(p[p.length - 1].x, p[p.length - 1].y); t.stroke(); break;
    }
    case 'highlight': t.globalCompositeOperation = 'multiply'; t.globalAlpha = 0.45; t.fillStyle = m.color === '#FFFFFF' ? '#FFD60A' : m.color; t.fillRect(r.x, r.y, r.w, r.h); break;
    case 'text': drawText(t, m); break;
    case 'image': {
      const placed = decoded.get(m.asset);
      // A project whose image data is damaged keeps a box in its place, so it can still be selected and deleted.
      if (placed) t.drawImage(placed, r.x, r.y, r.w, r.h); else { t.fillStyle = 'rgba(112,112,117,.35)'; t.fillRect(r.x, r.y, r.w, r.h); }
      break;
    }
    case 'step': {
      const radius = Math.max(14, m.stroke * 3.5);
      t.shadowColor = 'rgba(0,0,0,.3)'; t.shadowBlur = 4;
      t.beginPath(); t.arc(m.x, m.y, radius, 0, Math.PI * 2); t.fill(); t.shadowColor = 'transparent';
      t.fillStyle = m.color === '#FFFFFF' || m.color === '#FFD60A' ? '#1D1D1F' : '#fff';
      t.font = `700 ${radius * 1.15}px ${getComputedStyle(document.body).fontFamily}`; t.textAlign = 'center'; t.textBaseline = 'middle';
      t.fillText(String(m.n), m.x, m.y + 1); break;
    }
    case 'blur': {
      t.beginPath(); t.rect(r.x, r.y, r.w, r.h); t.clip();
      t.filter = `blur(${Math.max(8, Math.min(r.w, r.h) / 10)}px)`; t.drawImage(image, 0, 0); break;
    }
    case 'pixelate': {
      if (r.w < 2 || r.h < 2) break;
      const block = Math.max(8, Math.round(Math.min(r.w, r.h) / 12));
      const small = document.createElement('canvas'); small.width = Math.max(1, Math.round(r.w / block)); small.height = Math.max(1, Math.round(r.h / block));
      small.getContext('2d').drawImage(image, r.x, r.y, r.w, r.h, 0, 0, small.width, small.height);
      t.imageSmoothingEnabled = false; t.drawImage(small, r.x, r.y, r.w, r.h); break;
    }
    case 'spotlight': {
      t.fillStyle = 'rgba(0,0,0,.55)'; t.beginPath(); t.rect(0, 0, image.naturalWidth, image.naturalHeight);
      t.roundRect(r.x + r.w, r.y, -r.w, r.h, 10); t.fill('evenodd'); break;
    }
    case 'loupe': {
      // A round lens over the box: what's at its centre, enlarged, with a rim in the mark's colour.
      const radius = Math.min(r.w, r.h) / 2;
      if (radius < 4) break;
      const cx = r.x + r.w / 2, cy = r.y + r.h / 2, seen = radius / LOUPE_ZOOM;
      t.save(); t.shadowColor = 'rgba(0,0,0,.35)'; t.shadowBlur = Math.max(8, radius / 5); t.shadowOffsetY = Math.max(2, radius / 30);
      t.beginPath(); t.arc(cx, cy, radius, 0, Math.PI * 2); t.fillStyle = '#fff'; t.fill(); t.restore();
      t.save(); t.beginPath(); t.arc(cx, cy, radius, 0, Math.PI * 2); t.clip();
      t.imageSmoothingQuality = 'high'; t.drawImage(image, cx - seen, cy - seen, seen * 2, seen * 2, cx - radius, cy - radius, radius * 2, radius * 2);
      t.restore();
      t.lineWidth = Math.max(2, m.stroke); t.beginPath(); t.arc(cx, cy, radius, 0, Math.PI * 2); t.stroke(); break;
    }
  }
  t.restore();
}

function bounds(m) {
  if (m.w !== undefined) return G.normalize(m);
  if (isSegment(m)) return M.pathBounds(m);
  if (m.type === 'pen') {
    const xs = m.points.map((p) => p.x), ys = m.points.map((p) => p.y);
    return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  }
  if (m.type === 'text') return measureText(ctx, m).bounds;
  if (m.type === 'step') { const r = Math.max(14, m.stroke * 3.5); return { x: m.x - r, y: m.y - r, w: r * 2, h: r * 2 }; }
  return { x: 0, y: 0, w: 0, h: 0 };
}

function handlePoints(m) {
  if (M.isCurved(m)) return [{ x: m.x1, y: m.y1, k: 'p1' }, { x: m.x2, y: m.y2, k: 'p2' }, { ...M.curveControl(m), k: 'bend' }];
  if (isSegment(m)) return [{ x: m.x1, y: m.y1, k: 'p1' }, { x: m.x2, y: m.y2, k: 'p2' }];
  if (isRectLike(m)) { const r = G.normalize(m); return [{ x: r.x, y: r.y, k: 'nw' }, { x: r.x + r.w, y: r.y, k: 'ne' }, { x: r.x, y: r.y + r.h, k: 'sw' }, { x: r.x + r.w, y: r.y + r.h, k: 'se' }]; }
  return [];
}

function drawHandles(t, m) {
  const s = 1 / displayScale(), b = bounds(m);
  t.save(); t.setLineDash([4 * s, 3 * s]); t.strokeStyle = SELECTION; t.lineWidth = 1 * s;
  if (!isSegment(m)) t.strokeRect(b.x - 4 * s, b.y - 4 * s, b.w + 8 * s, b.h + 8 * s);
  t.setLineDash([]);
  for (const p of handlePoints(m)) { t.fillStyle = '#fff'; t.beginPath(); t.arc(p.x, p.y, 5 * s, 0, Math.PI * 2); t.fill(); t.stroke(); }
  t.restore();
}

function drawCropOverlay(t) {
  const r = pendingCrop || doc.crop || { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight }, s = 1 / displayScale();
  t.save(); t.fillStyle = 'rgba(0,0,0,.5)'; t.beginPath(); t.rect(0, 0, image.naturalWidth, image.naturalHeight); t.rect(r.x + r.w, r.y, -r.w, r.h); t.fill('evenodd');
  t.strokeStyle = '#fff'; t.lineWidth = 1.5 * s; t.strokeRect(r.x, r.y, r.w, r.h);
  t.globalAlpha = 0.35; t.lineWidth = 1 * s; t.beginPath();
  for (const f of [1 / 3, 2 / 3]) { t.moveTo(r.x + r.w * f, r.y); t.lineTo(r.x + r.w * f, r.y + r.h); t.moveTo(r.x, r.y + r.h * f); t.lineTo(r.x + r.w, r.y + r.h * f); }
  t.stroke(); t.globalAlpha = 1; t.fillStyle = '#fff';
  for (const [x, y] of [[r.x, r.y], [r.x + r.w, r.y], [r.x, r.y + r.h], [r.x + r.w, r.y + r.h]]) t.fillRect(x - 5 * s, y - 5 * s, 10 * s, 10 * s);
  // The part every phone and TV shows, for sizes that are cut down on smaller screens.
  const safe = S.safeArea(r, cropSize);
  if (safe) {
    t.setLineDash([6 * s, 4 * s]); t.lineWidth = 1.5 * s; t.strokeRect(safe.x, safe.y, safe.w, safe.h); t.setLineDash([]);
    t.font = `600 ${12 * s}px system-ui, sans-serif`; t.textBaseline = 'top'; t.fillText('Shown on every device', safe.x + 6 * s, safe.y + 6 * s);
  }
  t.restore();
}

// ---- Hit testing ------------------------------------------------------------------------------

function hit(p) {
  const tol = 8 / displayScale();
  for (let i = doc.marks.length - 1; i >= 0; i--) {
    const m = doc.marks[i];
    if (isSegment(m) ? M.distanceToPath(p, m) < tol + m.stroke : m.type === 'pen' ? m.points.some((q) => Math.hypot(q.x - p.x, q.y - p.y) < tol + m.stroke) : G.contains(inflate(bounds(m), tol), p)) return m;
  }
  return null;
}
const inflate = (r, d) => ({ x: r.x - d, y: r.y - d, w: r.w + d * 2, h: r.h + d * 2 });
function handleAt(p, m) { const tol = 9 / displayScale(); return handlePoints(m).find((h) => Math.hypot(h.x - p.x, h.y - p.y) < tol) || null; }

// ---- History ------------------------------------------------------------------------------------

const snapshot = () => JSON.stringify(doc);
function commit() {
  history.push(lastState); if (history.length > 200) history.shift();
  future = []; lastState = snapshot(); dirty = true; forgetOldImages(); scheduleSave(); updateButtons();
}
// Every rotate or resize keeps a full image for undo, so only the most recent ones stay undoable.
function forgetOldImages() {
  while (M.unusedAssets(assets, [lastState]).length > 30 && history.length) {
    history.shift();
    for (const id of M.unusedAssets(assets, [lastState, ...history])) { delete assets[id]; decoded.delete(id); }
  }
}
let lastState = snapshot();
function undo() { if (!history.length) return; future.push(snapshot()); doc = JSON.parse(history.pop()); lastState = snapshot(); selected = null; afterDocChange(); }
function redo() { if (!future.length) return; history.push(snapshot()); doc = JSON.parse(future.pop()); lastState = snapshot(); selected = null; afterDocChange(); }
function afterDocChange() { syncSource(); dirty = true; scheduleSave(); syncPanel(); updateButtons(); syncWatermark(); loadBgImage().then(render); }
function syncSource() { image = decoded.get(doc.source) || original; }
function updateButtons() { $('#undo').disabled = !history.length; $('#redo').disabled = !future.length; $('#undo').style.opacity = history.length ? 1 : 0.4; $('#redo').style.opacity = future.length ? 1 : 0.4; }

// ---- Pointer ------------------------------------------------------------------------------------

stage.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  finishTextEdit();
  const p = toImage(e);
  if (tool === 'crop') {
    const r = pendingCrop || doc.crop || { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight };
    const corner = [['nw', r.x, r.y], ['ne', r.x + r.w, r.y], ['sw', r.x, r.y + r.h], ['se', r.x + r.w, r.y + r.h]].find(([, x, y]) => Math.hypot(x - p.x, y - p.y) < 14 / displayScale());
    drag = corner ? { kind: 'crop-corner', corner: corner[0], start: p, orig: { ...r } } : G.contains(r, p) && pendingCrop ? { kind: 'crop-move', start: p, orig: { ...r } } : { kind: 'crop-new', start: p };
    return;
  }
  if (tool === 'select') {
    if (selected) { const h = handleAt(p, selected); if (h) { drag = { kind: 'handle', handle: h.k, start: p, orig: JSON.parse(JSON.stringify(selected)) }; return; } }
    selected = hit(p);
    if (selected) drag = { kind: 'move', start: p, orig: JSON.parse(JSON.stringify(selected)) };
    render(); return;
  }
  if (tool === 'text') { const existing = hit(p); if (existing && existing.type === 'text') return editText(existing); return editText(null, p); }
  if (tool === 'step') {
    const n = doc.marks.filter((m) => m.type === 'step').length + 1;
    doc.marks.push({ type: 'step', x: p.x, y: p.y, n, color, stroke }); commit(); render(); return;
  }
  const mark = tool === 'pen' ? { type: 'pen', points: [p], color, stroke }
    : tool === 'arrow' ? { type: tool, x1: p.x, y1: p.y, x2: p.x, y2: p.y, color, stroke, style: styles.arrow }
    : tool === 'line' || tool === 'measure' ? { type: tool, x1: p.x, y1: p.y, x2: p.x, y2: p.y, color, stroke }
    : tool === 'stamp' ? { type: tool, x: p.x, y: p.y, w: 0, h: 0, color, stroke, text: styles.stamp }
    : { type: tool, x: p.x, y: p.y, w: 0, h: 0, color, stroke };
  if (tool === 'highlight' && e.altKey === false) mark.smart = true;
  doc.marks.push(mark);
  drag = { kind: 'draw', mark, start: p };
});

addEventListener('mousemove', (e) => {
  if (!drag) { if (tool === 'select') { const p = toImage(e); stage.classList.toggle('moving', !!hit(p)); } return; }
  const p = toImage(e), dx = p.x - drag.start.x, dy = p.y - drag.start.y;
  if (drag.kind === 'draw') {
    const m = drag.mark;
    if (m.type === 'pen') m.points.push(p);
    else if (isSegment(m)) {
      let x2 = p.x, y2 = p.y;
      if (e.shiftKey) { const a = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4), len = Math.hypot(dx, dy); x2 = m.x1 + len * Math.cos(a); y2 = m.y1 + len * Math.sin(a); }
      m.x2 = x2; m.y2 = y2;
    } else {
      m.w = dx; m.h = e.shiftKey ? Math.sign(dy || 1) * Math.abs(dx) : dy;
      if (m.type === 'highlight' && m.smart && !e.altKey) m.h = Math.sign(dy || 1) * Math.max(Math.abs(dy), 18);
    }
  } else if (drag.kind === 'move') {
    moveMark(selected, drag.orig, dx, dy);
  } else if (drag.kind === 'handle') {
    // Images keep their shape unless Shift is held; every other mark is the other way round.
    resizeMark(selected, drag.orig, drag.handle, p, selected.type === 'image' ? !e.shiftKey : e.shiftKey);
  } else if (drag.kind.startsWith('crop')) {
    const full = { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight };
    const aspect = cropSize && cropSize.w / cropSize.h;
    if (drag.kind === 'crop-new') pendingCrop = aspect ? S.dragged(drag.start, p, aspect, full) : G.dragRect(drag.start, p, { square: e.shiftKey, bounds: full });
    else if (drag.kind === 'crop-move') pendingCrop = G.nudge(drag.orig, dx, dy, { bounds: full });
    else if (aspect) pendingCrop = S.cornered(drag.orig, drag.corner, p, aspect, full);
    else {
      const o = drag.orig, c = drag.corner;
      const x1 = c.includes('w') ? o.x + dx : o.x, y1 = c.includes('n') ? o.y + dy : o.y;
      const x2 = c.includes('e') ? o.x + o.w + dx : o.x + o.w, y2 = c.includes('s') ? o.y + o.h + dy : o.y + o.h;
      pendingCrop = G.intersect(G.normalize({ x: x1, y: y1, w: x2 - x1, h: y2 - y1 }), full);
    }
    $('#cropBar').classList.add('show'); showCropNote();
  }
  render();
});

addEventListener('mouseup', () => {
  if (!drag) return;
  const d = drag; drag = null;
  if (d.kind === 'draw') {
    const b = bounds(d.mark);
    if (d.mark.type === 'stamp' && b.w < 8 && b.h < 8) { const size = Math.round(Math.max(48, Math.min(image.naturalWidth, image.naturalHeight) / 10)); Object.assign(d.mark, { x: d.start.x - size / 2, y: d.start.y - size / 2, w: size, h: size }); }
    else if (d.mark.type !== 'pen' && b.w < 3 && b.h < 3) { doc.marks.pop(); render(); return; }
    if (d.mark.w !== undefined) Object.assign(d.mark, G.normalize(d.mark));
    commit();
  } else if (d.kind === 'move' || d.kind === 'handle') {
    if (JSON.stringify(selected) !== JSON.stringify(d.orig)) { if (selected.w !== undefined) Object.assign(selected, G.normalize(selected)); commit(); }
  }
  render();
});

stage.addEventListener('dblclick', (e) => { const m = hit(toImage(e)); if (m && m.type === 'text') editText(m); });

function moveMark(m, o, dx, dy) {
  if (m.points) m.points = o.points.map((q) => ({ x: q.x + dx, y: q.y + dy }));
  if (isSegment(m)) Object.assign(m, { x1: o.x1 + dx, y1: o.y1 + dy, x2: o.x2 + dx, y2: o.y2 + dy });
  if (o.cx !== undefined) Object.assign(m, { cx: o.cx + dx, cy: o.cy + dy });
  else if (m.x !== undefined) Object.assign(m, { x: o.x + dx, y: o.y + dy });
}
function resizeMark(m, o, handle, p, keepRatio) {
  if (handle === 'p1') { m.x1 = p.x; m.y1 = p.y; return; }
  if (handle === 'p2') { m.x2 = p.x; m.y2 = p.y; return; }
  if (handle === 'bend') { m.cx = p.x; m.cy = p.y; return; }
  const r = G.normalize(o);
  const fx = handle.includes('w') ? r.x + r.w : r.x, fy = handle.includes('n') ? r.y + r.h : r.y;
  let w = p.x - fx, h = p.y - fy;
  if (keepRatio && r.h) h = Math.sign(h || 1) * Math.abs(w) * (r.h / r.w);
  Object.assign(m, { x: fx, y: fy, w, h });
}

// ---- Text ---------------------------------------------------------------------------------------

let textEditor = null;
function editText(mark, at) {
  finishTextEdit();
  const target = mark || { type: 'text', x: at.x, y: at.y, text: '', color, size: Math.round(prefs.annotate?.font || 28) * Math.max(1, image.naturalWidth / 1600), stroke, style: styles.text };
  const r = stage.getBoundingClientRect(), L = layout(), s = displayScale(), main = $('main').getBoundingClientRect();
  const area = el('textarea', { class: 'text-edit', spellcheck: 'false', rows: '1' });
  area.value = target.text;
  Object.assign(area.style, {
    left: `${r.left - main.left + (target.x - L.base.x + L.ox) * s}px`, top: `${r.top - main.top + (target.y - L.base.y + L.oy) * s}px`,
    fontSize: `${target.size * s}px`, fontWeight: M.textWeight(target), color: M.textInk(target), fontFamily: fontFamily(), minWidth: '40px'
  });
  const look = M.textStyle(target);
  if (look === 'label' || look === 'bubble') Object.assign(area.style, { background: target.color, boxShadow: `0 0 0 ${target.size * s * 0.2}px ${target.color}`, borderRadius: '1px' });
  if (look === 'outline') area.style.webkitTextStroke = `${target.size * s * 0.04}px ${target.color}`;
  const grow = () => { area.style.height = 'auto'; area.style.height = `${area.scrollHeight}px`; area.style.width = '0'; area.style.width = `${Math.max(40, area.scrollWidth + 8)}px`; };
  area.addEventListener('input', grow);
  area.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Escape' || (e.key === 'Enter' && (e.metaKey || e.ctrlKey))) finishTextEdit(); });
  $('main').append(area); grow(); setTimeout(() => area.focus(), 0);
  if (mark) { mark.hidden = true; doc.marks = doc.marks.filter((m) => m !== mark); render(); }
  textEditor = { area, target };
}
function finishTextEdit() {
  if (!textEditor) return;
  const { area, target } = textEditor; textEditor = null;
  target.text = area.value.replace(/\s+$/, ''); delete target.hidden; area.remove();
  if (target.text) { doc.marks.push(target); selected = target; }
  commit(); render();
}

// ---- Toolbar ------------------------------------------------------------------------------------

function setTool(next) {
  finishTextEdit();
  if (tool === 'crop' && next !== 'crop') cancelCrop();
  tool = next; selected = null;
  stage.className = `tool-${tool}`;
  $$('#tools button').forEach((b) => b.classList.toggle('active', b.dataset.tool === tool));
  if (tool === 'crop') { pendingCrop = doc.crop ? { ...doc.crop } : null; $('#cropBar').classList.add('show'); showCropNote(); }
  render();
}
function applyCrop() {
  const size = cropSize, r = pendingCrop && G.normalize(pendingCrop);
  pendingCrop = null; $('#cropBar').classList.remove('show'); tool = 'select'; setTool('select');
  if (!r || r.w <= 4 || r.h <= 4) return;
  if (!size) { doc.crop = r; commit(); return; }
  // A size crops and then scales to exactly its pixels, as one step that one undo takes back.
  doc.crop = r;
  bake((content) => ({ w: size.w, h: size.h, paint: (t) => t.drawImage(content, 0, 0, size.w, size.h) }));
  toast(`${size.group} ${size.name}: ${size.w} × ${size.h}`);
}
function cancelCrop() { pendingCrop = null; $('#cropBar').classList.remove('show'); }
function showCropNote() { $('#cropNote').textContent = S.note(pendingCrop, cropSize); }
function chooseCropSize(id) {
  cropSize = S.byId(id);
  if (cropSize) pendingCrop = S.centered({ x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight }, cropSize.w / cropSize.h);
  showCropNote(); render();
}
for (const group of [...new Set(S.SIZES.map((x) => x.group))]) {
  const g = el('optgroup', { label: group });
  for (const x of S.SIZES.filter((y) => y.group === group)) g.append(el('option', { value: x.id }, `${x.group} ${x.name}`));
  $('#cropSize').append(g);
}
$('#cropSize').addEventListener('change', (e) => { chooseCropSize(e.target.value); e.target.blur(); });

$('#tools').append(...TOOLS.map(([id, iconName, title, key]) => el('button', { 'data-tool': id, title: `${title} (${key.toUpperCase()})`, html: icon(iconName), onclick: () => setTool(id) })));
$('#cropApply').onclick = applyCrop;
$('#cropCancel').onclick = () => setTool('select');
$('#cropReset').onclick = () => { pendingCrop = null; cropSize = null; $('#cropSize').value = ''; showCropNote(); if (doc.crop) { doc.crop = null; commit(); } render(); };

function setColor(next) { color = next; $('#swatch').style.background = next; if (selected && selected.type !== 'image') { selected.color = next; commit(); render(); } still.invoke('settings:set', { annotate: { color: next } }); }
$('#color').onclick = (e) => {
  $$('.menu').forEach((m) => m.remove());
  const menu = el('div', { class: 'menu' }), grid = el('div', { class: 'palette' });
  for (const c of COLORS) grid.append(el('button', { class: c === color ? 'active' : '', style: `background:${c}`, title: c, onclick: () => { menu.remove(); setColor(c); } }));
  const custom = el('input', { type: 'color', value: color, style: 'width:100%;height:28px;border:0;background:none', oninput: (ev) => setColor(ev.target.value.toUpperCase()) });
  menu.append(grid, custom); document.body.append(menu);
  // Colours picked with C while capturing, newest first.
  still.invoke('settings:get').then((current) => {
    const recent = (current.recentColors || []).filter((c) => /^#[0-9A-F]{6}$/i.test(c));
    if (!recent.length || !menu.isConnected) return;
    const row = el('div', { class: 'palette' });
    for (const c of recent) row.append(el('button', { class: c.toUpperCase() === color.toUpperCase() ? 'active' : '', style: `background:${c}`, title: c, onclick: () => { menu.remove(); setColor(c.toUpperCase()); } }));
    menu.insertBefore(el('div', { class: 'menu-label' }, 'Recent'), custom); menu.insertBefore(row, custom);
  }).catch(() => {});
  const r = e.currentTarget.getBoundingClientRect(); menu.style.left = `${r.left - 60}px`; menu.style.top = `${r.bottom + 6}px`;
  setTimeout(() => addEventListener('mousedown', function close(ev) { if (!menu.contains(ev.target)) { menu.remove(); removeEventListener('mousedown', close); } }), 0);
};
$('#stroke').onclick = (e) => popupMenu(e.currentTarget, STROKES.map((s) => ({ label: `${s} px${s === stroke ? '  ✓' : ''}`, action: () => { stroke = s; if (selected && selected.stroke !== undefined) { selected.stroke = s; commit(); render(); } still.invoke('settings:set', { annotate: { stroke: s } }); } })));
// The style menu follows what's being drawn or selected, and is greyed out for marks without styles.
const styleKind = () => { const type = selected ? selected.type : tool; return type === 'arrow' || type === 'text' || type === 'stamp' ? type : null; };
let styleIcon = 'arrow';
function syncStyleButton() {
  const kind = styleKind();
  $('#style').disabled = !kind;
  if (kind && kind !== styleIcon) { styleIcon = kind; $('#style').innerHTML = icon(kind === 'arrow' ? 'move-up-right' : kind === 'stamp' ? 'smile-plus' : 'type'); refreshIcons(); }
}
function setStyle(kind, value) {
  styles[kind] = value;
  if (selected && kind === 'stamp') { selected.text = value; commit(); render(); }
  else if (selected) { selected.style = value; commit(); render(); }
  still.invoke('settings:set', { annotate: { [`${kind}Style`]: value } });
}
$('#style').onclick = (e) => {
  const anchor = e.currentTarget;
  finishTextEdit();
  const kind = styleKind(); if (!kind) return;
  if (kind === 'stamp') { const current = selected ? selected.text : styles.stamp; return popupMenu(anchor, STAMPS.map((emoji) => ({ label: `${emoji}${emoji === current ? '  ✓' : ''}`, action: () => setStyle('stamp', emoji) }))); }
  const names = kind === 'arrow' ? M.ARROW_STYLES : M.TEXT_STYLES;
  const current = selected ? (kind === 'arrow' ? M.arrowStyle(selected) : M.textStyle(selected)) : styles[kind];
  popupMenu(anchor, names.map((name) => ({ label: `${name[0].toUpperCase()}${name.slice(1)}${name === current ? '  ✓' : ''}`, action: () => setStyle(kind, name) })));
};
$('#transform').onclick = (e) => popupMenu(e.currentTarget, [
  { label: 'Resize Image…', icon: 'scaling', action: openResize }, '-',
  { label: 'Rotate Clockwise', icon: 'rotate-cw', action: () => reorient('cw') },
  { label: 'Rotate Counterclockwise', icon: 'rotate-ccw', action: () => reorient('ccw') },
  { label: 'Flip Horizontally', icon: 'flip-horizontal-2', action: () => reorient('flip-h') },
  { label: 'Flip Vertically', icon: 'flip-vertical-2', action: () => reorient('flip-v') }, '-',
  { label: 'Add Image…', icon: 'image-plus', action: chooseImage }
]);
$('#undo').onclick = undo; $('#redo').onclick = redo;
$('#background').onclick = () => { $('#panel').classList.toggle('open'); if ($('#panel').classList.contains('open') && doc.bg.style === 'none') { doc.bg.style = 'midnight'; commit(); syncPanel(); } render(); setTimeout(fitZoom, 200); };

// ---- Resize, rotate and flip --------------------------------------------------------------------

async function decodeAsset(id) {
  if (decoded.has(id)) return;
  const loaded = new Image(); loaded.src = assets[id]; await loaded.decode();
  decoded.set(id, loaded);
}
async function storeAsset(dataUrl) { const id = M.addAsset(assets, dataUrl); await decodeAsset(id); return id; }

// The capture as it looks now, marks and crop included, without its background.
function currentContent() {
  const b = doc.crop || { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight }, out = document.createElement('canvas');
  out.width = Math.round(b.w); out.height = Math.round(b.h);
  const t = out.getContext('2d'); t.translate(-b.x, -b.y); t.drawImage(image, 0, 0);
  for (const m of doc.marks) drawMark(t, m);
  return out;
}

// Like the Mac app, this bakes the marks and crop into a new image, and undo brings them back. The new image is saved
// in the project so it survives reopening. `plan` gets the current content and returns the output size and how to draw it.
let baking = false;
async function bake(plan) {
  if (baking) return;
  finishTextEdit();
  if (tool === 'crop') setTool('select');
  baking = true;
  try {
    const { w, h, paint } = plan(currentContent()), out = document.createElement('canvas'); out.width = w; out.height = h;
    const t = out.getContext('2d'); t.imageSmoothingQuality = 'high'; paint(t);
    const url = out.toDataURL('image/png');
    if (url === 'data:,') { toast('That size is too large to edit.'); return; }
    doc.source = await storeAsset(url); doc.marks = []; doc.crop = null; selected = null;
    syncSource(); commit(); render();
  } catch (error) { toast(`Couldn’t change the image: ${explain(error)}`); } finally { baking = false; }
}
const reorient = (kind) => bake((content) => {
  const o = M.orient({ w: content.width, h: content.height }, kind);
  return { w: o.w, h: o.h, paint: (t) => { t.setTransform(...o.matrix); t.drawImage(content, 0, 0); } };
});

let resizeFrom = { w: 1, h: 1 };
function openResize() {
  const b = doc.crop || { w: image.naturalWidth, h: image.naturalHeight };
  resizeFrom = { w: Math.round(b.w), h: Math.round(b.h) };
  $('#resizeW').value = resizeFrom.w; $('#resizeH').value = resizeFrom.h; $('#resizeLock').checked = true;
  $('#resizeSheet').hidden = false; checkResize(); $('#resizeW').focus(); $('#resizeW').select();
}
const closeResize = () => { $('#resizeSheet').hidden = true; };
function checkResize() {
  const w = $('#resizeW').value, h = $('#resizeH').value, problem = M.resizeProblem(Number(w), Number(h));
  $('#resizeError').textContent = w && h ? problem || '' : ''; $('#resizeApply').disabled = !!problem;
  return !problem;
}
$('#resizeW').addEventListener('input', (e) => { if ($('#resizeLock').checked && e.target.value > 0) $('#resizeH').value = M.linkedSide(e.target.value, resizeFrom.w, resizeFrom.h); checkResize(); });
$('#resizeH').addEventListener('input', (e) => { if ($('#resizeLock').checked && e.target.value > 0) $('#resizeW').value = M.linkedSide(e.target.value, resizeFrom.h, resizeFrom.w); checkResize(); });
$('#resizeCancel').onclick = closeResize;
$('#resizeSheet').addEventListener('mousedown', (e) => { if (e.target === e.currentTarget) closeResize(); });
$('#resizeForm').addEventListener('submit', (e) => {
  e.preventDefault(); if (!checkResize()) return;
  const w = Number($('#resizeW').value), h = Number($('#resizeH').value);
  closeResize(); bake((content) => ({ w, h, paint: (t) => t.drawImage(content, 0, 0, w, h) }));
});

// ---- Placed images ------------------------------------------------------------------------------

// Copies an image's pixels into the project through a canvas, so any format the web view can show is kept as PNG.
// Very large photos are scaled down, because project data is written out with every autosave.
async function readImage(src) {
  const loaded = new Image(); loaded.crossOrigin = 'anonymous'; loaded.src = src; await loaded.decode();
  const fitted = G.fit({ w: loaded.naturalWidth, h: loaded.naturalHeight }, { w: 4096, h: 4096 }), out = document.createElement('canvas');
  out.width = Math.round(fitted.w); out.height = Math.round(fitted.h);
  const t = out.getContext('2d'); t.imageSmoothingQuality = 'high'; t.drawImage(loaded, 0, 0, out.width, out.height);
  return { id: await storeAsset(out.toDataURL('image/png')), size: { w: out.width, h: out.height } };
}
async function addImages(sources, point) {
  finishTextEdit();
  if (tool === 'crop') setTool('select');
  const at = point ? toImage(point) : null, canvas = doc.crop || { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight };
  let last = null, failed = 0;
  for (const [i, src] of sources.entries()) {
    try {
      const { id, size } = await readImage(src);
      last = { type: 'image', asset: id, ...M.placeImage(size, canvas, at ? { x: at.x + i * 24, y: at.y + i * 24 } : null) };
      doc.marks.push(last);
    } catch { failed++; }
  }
  if (failed) toast(failed === 1 ? 'That image couldn’t be opened.' : `${failed} images couldn’t be opened.`);
  if (!last) return;
  commit(); setTool('select'); selected = last; render();
}
async function chooseImage() { const data = await still.invoke('editor:openImage'); if (data) await addImages([data]); }

// Tauri takes file drops before the page sees them, so HTML drag events never fire. Its drop event gives the paths,
// and allows those files on the asset protocol.
function listenForDrops() {
  window.__TAURI__.webviewWindow.getCurrentWebviewWindow().onDragDropEvent(({ payload }) => {
    if (payload.type === 'enter') $('#dropHint').hidden = !M.droppedImages(payload.paths).length;
    else if (payload.type === 'leave') $('#dropHint').hidden = true;
    else if (payload.type === 'drop') {
      $('#dropHint').hidden = true;
      const paths = M.droppedImages(payload.paths);
      if (!paths.length) { if (payload.paths.length) toast('Only PNG, JPEG, GIF, WebP and BMP images can be added.'); return; }
      addImages(paths.map((path) => still.fileUrl(path)), M.dropPoint(payload.position, devicePixelRatio, still.platform));
    }
  });
}

// ---- Background panel ---------------------------------------------------------------------------

$('#gradients').append(el('button', { title: 'None', 'data-bg': 'none', html: icon('ban', 14), style: 'background:var(--bg-elevated)' }),
  ...Object.entries(GRADIENTS).map(([name, [a, b]]) => el('button', { title: name[0].toUpperCase() + name.slice(1), 'data-bg': name, style: `background:linear-gradient(135deg, ${a}, ${b})` })));
$('#gradients').addEventListener('click', (e) => { const b = e.target.closest('[data-bg]'); if (!b) return; doc.bg.style = b.dataset.bg; commit(); syncPanel(); render(); });
for (const key of ['padding', 'radius']) $(`#${key}`).addEventListener('input', (e) => { doc.bg[key] = Number(e.target.value); syncPanel(); render(); });
for (const key of ['padding', 'radius']) $(`#${key}`).addEventListener('change', commit);
$('#shadow').onchange = (e) => { doc.bg.shadow = e.target.checked; commit(); render(); };
$('#aspect').onchange = (e) => { doc.bg.aspect = Number(e.target.value); commit(); render(); };
$('#balance').onchange = (e) => { doc.bg.balance = e.target.checked; if (e.target.checked) autoBalance(); commit(); syncPanel(); render(); };
$('#customBg').onclick = async () => { const data = await still.invoke('editor:openImage'); if (!data) return; doc.bg.custom = data; doc.bg.style = 'custom'; await loadBgImage(); commit(); syncPanel(); render(); };
function syncPanel() {
  $$('#gradients button').forEach((b) => b.classList.toggle('active', b.dataset.bg === doc.bg.style));
  $('#padding').value = doc.bg.padding; $('#paddingValue').textContent = doc.bg.padding;
  $('#radius').value = doc.bg.radius; $('#radiusValue').textContent = doc.bg.radius;
  $('#shadow').checked = doc.bg.shadow; $('#aspect').value = String(doc.bg.aspect); $('#balance').checked = !!doc.bg.balance;
}
// Picks padding relative to the capture so small and large shots look balanced.
function autoBalance() { const b = base(); doc.bg.padding = Math.round(Math.min(160, Math.max(32, Math.min(b.w, b.h) * 0.08))); }
async function loadBgImage() {
  if (!doc.bg.custom) { bgImage = null; return; }
  if (bgImage && bgImage.src === doc.bg.custom) return;
  bgImage = new Image(); bgImage.crossOrigin = 'anonymous'; bgImage.src = doc.bg.custom; await bgImage.decode().catch(() => {});
}

// ---- Zoom ---------------------------------------------------------------------------------------

function fitZoom() {
  // zoom is in image pixels per device pixel, so 100% shows the capture at its true size.
  const avail = { w: scroller.clientWidth - 56, h: scroller.clientHeight - 56 }, dpr = devicePixelRatio || 1;
  const scale = zoom ? zoom / dpr : Math.min(1 / dpr, avail.w / stage.width, avail.h / stage.height) || 1;
  stage.style.width = `${Math.round(stage.width * scale)}px`; stage.style.height = `${Math.round(stage.height * scale)}px`;
  $('#zoom').textContent = zoom ? `${Math.round(zoom * 100)}%` : 'Fit';
  $('#size').textContent = `${stage.width} × ${stage.height}`;
}
addEventListener('resize', fitZoom);
$('#zoom').onclick = (e) => popupMenu(e.currentTarget, [['Fit to Window', 0], ['50%', 0.5], ['100%', 1], ['150%', 1.5], ['200%', 2], ['400%', 4]].map(([label, value]) => ({ label, action: () => { zoom = value; fitZoom(); } })));
scroller.addEventListener('wheel', (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  e.preventDefault(); const current = zoom || displayScale() * (devicePixelRatio || 1);
  zoom = Math.min(8, Math.max(0.1, current * (e.deltaY < 0 ? 1.1 : 0.9))); fitZoom();
}, { passive: false });

// ---- Output -------------------------------------------------------------------------------------

function flattened() {
  const prevTool = tool; tool = tool === 'crop' ? 'select' : tool;
  const out = document.createElement('canvas'), L = layout(false);
  out.width = L.w; out.height = L.h;
  const prevSel = selected; selected = null; render(out.getContext('2d'), { handles: false }); selected = prevSel; tool = prevTool;
  return out;
}
const flatten = () => flattened().toDataURL('image/png');
// The same picture, encoded in pieces rather than all at once: autosave happens while someone is still drawing.
const flattenInBackground = () => new Promise((done, failed) => flattened().toBlob((blob) => {
  if (!blob) return failed(new Error('The image is too large'));
  const reader = new FileReader(); reader.onload = () => done(reader.result); reader.onerror = () => failed(reader.error); reader.readAsDataURL(blob);
}, 'image/png'));
const project = () => M.projectFile(doc, assets);
let captureGone = false, saving = Promise.resolve();
// One save at a time, so a slower older save can never land on top of a newer one.
function persist() { saving = saving.catch(() => {}).then(saveEdits); return saving; }
async function saveEdits() {
  if (!itemId || !dirty || captureGone) return;
  dirty = false;
  // If saving fails, keep the edits marked unsaved and say so.
  // Encoding takes a moment and more edits can land meanwhile, so the project is copied now to match the picture.
  try { const edits = JSON.parse(JSON.stringify(project())); await still.invoke('editor:save', itemId, await flattenInBackground(), edits); }
  catch (e) {
    dirty = true;
    // The capture was deleted from History: stop autosaving rather than bring it back.
    if (String(e).includes('no longer exists')) { captureGone = true; toast('This capture was deleted. Use Save to keep a copy.'); return; }
    toast(`Couldn’t save your changes: ${explain(e)}`); throw e;
  }
}
function scheduleSave() { clearTimeout(saveTimer); saveTimer = setTimeout(() => persist().catch(() => {}), 900); }
// Closing the window (the close button, Alt+F4, Ctrl+W) waits for the last edits to be saved first;
// a save fired from beforeunload could be cut off when the page goes away.
window.__TAURI__.webviewWindow.getCurrentWebviewWindow().onCloseRequested(async (event) => {
  if (!itemId || !dirty || captureGone) return;
  event.preventDefault();
  clearTimeout(saveTimer);
  try { await persist(); } catch { return; }
  window.__TAURI__.webviewWindow.getCurrentWebviewWindow().destroy();
});
addEventListener('keydown', (e) => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'w') { e.preventDefault(); still.send('window:close'); } });

$('#copy').onclick = async () => { finishTextEdit(); await still.invoke('editor:copy', flatten()); toast('Copied to clipboard'); };
$('#save').onclick = async () => { finishTextEdit(); try { await persist(); const file = await still.invoke('editor:export', flatten(), document.title, false); if (file) toast(`Saved to ${file.split(/[\\/]/).slice(-2).join('/')}`); } catch (e) { toast(`Couldn’t save: ${explain(e)}`); } };
$('#saveAs').onclick = async () => { finishTextEdit(); try { const file = await still.invoke('editor:export', flatten(), document.title, true); if (file) toast('Saved'); } catch (e) { toast(`Couldn’t save: ${explain(e)}`); } };
$('#pin').onclick = () => still.invoke('editor:pin', flatten());
$('#upload').onclick = async () => { finishTextEdit(); toast('Uploading…'); try { const result = await still.invoke('cloud:uploadData', flatten(), document.title); toast(String(result).startsWith('http') ? 'Link copied' : 'Saved to iCloud Drive'); } catch (error) { toast(explain(error)); } };
$('#ocr').onclick = () => recognize();
async function recognize() {
  toast('Recognizing text…');
  try { const text = (await still.invoke('editor:ocr', flatten())).trim(); if (!text) return toast('No text found'); await navigator.clipboard.writeText(text); toast('Text copied'); }
  catch (error) { toast(`Text recognition failed: ${explain(error)}`); }
}
// Covers every email address, card number, key, IP address and phone number the text recognition finds with a
// redact box, as one step that a single undo takes back.
$('#watermark').onclick = () => { doc.watermark = doc.watermark === false; commit(); syncWatermark(); render(); toast(doc.watermark ? 'Watermark on' : 'Watermark off for this picture'); };
function syncWatermark() {
  const b = $('#watermark'), on = doc.watermark !== false;
  b.hidden = !StillWatermark.normalize(prefs.watermark);
  b.classList.toggle('on', on); b.setAttribute('aria-pressed', String(on));
  b.title = on ? 'Watermark on: click to leave it off this picture' : 'Watermark off for this picture: click to add it';
}
$('#private').onclick = (e) => popupMenu(e.currentTarget, [
  { label: 'Hide Private Info', icon: 'shield-check', action: hidePrivate },
  { label: 'Blur All Text', icon: 'droplet', action: blurAllText }
]);
// Blurs every line of text the recognition finds, as one step that a single undo takes back: the layout stays
// readable while the words don't.
async function blurAllText() {
  finishTextEdit(); toast('Looking for text…');
  try {
    const c = document.createElement('canvas'); c.width = image.naturalWidth; c.height = image.naturalHeight;
    c.getContext('2d').drawImage(image, 0, 0);
    const lines = await still.invoke('editor:ocrLines', c.toDataURL('image/png'));
    const boxes = StillPrivate.lineBoxes(lines);
    if (!boxes.length) return toast('No text found');
    for (const b of boxes) doc.marks.push({ type: 'blur', x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.w), h: Math.round(b.h), color, stroke });
    selected = null; commit(); render();
    toast(`Blurred ${boxes.length} line${boxes.length === 1 ? '' : 's'} of text. Undo brings them back.`);
  } catch (error) { toast(`Couldn’t look for text: ${explain(error)}`); }
}
async function hidePrivate() {
  finishTextEdit(); toast('Looking for private details…');
  try {
    const c = document.createElement('canvas'); c.width = image.naturalWidth; c.height = image.naturalHeight;
    c.getContext('2d').drawImage(image, 0, 0);
    const found = StillPrivate.boxes(await still.invoke('editor:ocrLines', c.toDataURL('image/png')));
    const covered = (b) => doc.marks.some((m) => m.type === 'redact' && m.x <= b.x + 1 && m.y <= b.y + 1 && m.x + m.w >= b.x + b.w - 1 && m.y + m.h >= b.y + b.h - 1);
    const fresh = found.filter((b) => !covered(b));
    if (!fresh.length) return toast(found.length ? 'Everything private is already hidden' : 'No private details found');
    for (const b of fresh) doc.marks.push({ type: 'redact', x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.w), h: Math.round(b.h), color, stroke });
    selected = null; commit(); render();
    toast(`Hid ${fresh.length} private detail${fresh.length === 1 ? '' : 's'}. Undo brings them back.`);
  } catch (error) { toast(`Couldn’t look for private details: ${explain(error)}`); }
}
dragOut($('#dragMe'), () => { finishTextEdit(); still.send('editor:drag', flatten()); });

// ---- Keyboard -----------------------------------------------------------------------------------

addEventListener('keydown', (e) => {
  if (!$('#resizeSheet').hidden) { if (e.key === 'Escape') closeResize(); return; }
  if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
  const mod = e.ctrlKey || e.metaKey, key = e.key.toLowerCase();
  if (mod && key === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
  if (mod && key === 'y') { e.preventDefault(); redo(); return; }
  if (mod && key === 'c') { e.preventDefault(); $('#copy').click(); return; }
  if (mod && key === 's') { e.preventDefault(); (e.shiftKey ? $('#saveAs') : $('#save')).click(); return; }
  if (mod && key === 'd' && selected) { e.preventDefault(); const copy = JSON.parse(JSON.stringify(selected)); moveMark(copy, JSON.parse(JSON.stringify(selected)), 20, 20); doc.marks.push(copy); selected = copy; commit(); render(); return; }
  if (mod && key === 'w') { still.send('window:close'); return; }
  if (mod && (key === '=' || key === '+')) { zoom = Math.min(8, (zoom || displayScale() * devicePixelRatio) * 1.25); fitZoom(); return; }
  if (mod && key === '-') { zoom = Math.max(0.1, (zoom || displayScale() * devicePixelRatio) * 0.8); fitZoom(); return; }
  if (mod && key === '0') { zoom = 0; fitZoom(); return; }
  if ((e.key === 'Delete' || e.key === 'Backspace') && selected) { doc.marks = doc.marks.filter((m) => m !== selected); selected = null; commit(); render(); return; }
  if (e.key === 'Enter' && tool === 'crop') return applyCrop();
  if (e.key === 'Escape') { if (tool === 'crop') return setTool('select'); selected = null; render(); return; }
  if (!mod && !e.altKey) { const match = TOOLS.find((t) => t[3] === key); if (match) setTool(match[0]); }
});

// ---- Startup ------------------------------------------------------------------------------------

// A tidy sample to try the tools on: everything is measured so it fits with any system font.
function demoImage() {
  const c = document.createElement('canvas'); c.width = 1200; c.height = 760; const t = c.getContext('2d');
  const font = (weight, size, family = 'system-ui, "Segoe UI", sans-serif') => `${weight} ${size}px ${family}`;
  const fit = (text, weight, size, max, family) => { let s = size; do { t.font = font(weight, s, family); } while (t.measureText(text).width > max && --s > 10); return s; };
  t.fillStyle = '#e8e8ed'; t.fillRect(0, 0, 1200, 760);
  t.shadowColor = 'rgba(0,0,0,.12)'; t.shadowBlur = 40; t.shadowOffsetY = 12;
  t.fillStyle = '#ffffff'; t.beginPath(); t.roundRect(120, 96, 960, 568, 22); t.fill();
  t.shadowColor = 'transparent';
  [['#e0938a', 156], ['#d9c27c', 180], ['#9fbf8f', 204]].forEach(([col, x]) => { t.fillStyle = col; t.beginPath(); t.arc(x, 130, 7, 0, Math.PI * 2); t.fill(); });
  const left = 180, max = 840;
  t.textBaseline = 'alphabetic';
  t.fillStyle = '#6e6e73'; t.font = font(700, 15); t.fillText('A LITTLE FIELD GUIDE', left, 200);
  t.fillStyle = '#1d1d1f'; t.font = font(700, fit('Make your point.', 700, 64, max, 'Georgia, "Times New Roman", serif'), 'Georgia, "Times New Roman", serif'); t.fillText('Make your point.', left, 276);
  t.fillStyle = '#86868b'; t.font = font(400, fit('A screenshot is worth a thousand explanations.', 400, 24, max)); t.fillText('A screenshot is worth a thousand explanations.', left, 322);
  const steps = ['Draw an arrow to the detail that matters.', 'Highlight the important part, add a note, or crop.', 'Copy it. Save it. Keep moving.'];
  steps.forEach((line, i) => {
    const y = 396 + i * 48;
    t.fillStyle = '#1d1d1f'; t.font = font(500, 22); t.fillText(String(i + 1).padStart(2, '0'), left, y);
    t.font = font(600, fit(line, 600, 22, max - 56)); t.fillText(line, left + 56, y);
  });
  t.fillStyle = '#e8ecdf'; t.beginPath(); t.roundRect(left, 556, max, 54, 10); t.fill();
  t.fillStyle = '#5d6857'; t.font = font(400, 19); t.fillText('Try redacting this:  example@still.local', left + 20, 590);
  return c.toDataURL();
}

(async () => {
  prefs = await applyTheme();
  color = prefs.annotate?.color || color; stroke = prefs.annotate?.stroke || stroke;
  if (M.ARROW_STYLES.includes(prefs.annotate?.arrowStyle)) styles.arrow = prefs.annotate.arrowStyle;
  if (M.TEXT_STYLES.includes(prefs.annotate?.textStyle)) styles.text = prefs.annotate.textStyle;
  if (STAMPS.includes(prefs.annotate?.stampStyle)) styles.stamp = prefs.annotate.stampStyle;
  $('#swatch').style.background = color;
  syncWatermark();
  if (prefs.platform !== 'darwin') addWindowControls();
  let src;
  if (itemId) {
    const item = await still.invoke('library:get', itemId);
    if (!item) { document.body.textContent = 'This capture is no longer in the library.'; return; }
    document.title = item.title; still.send('window:setTitle', item.title);
    if (item.project) { ({ doc, assets } = M.openProject(item.project, doc)); lastState = snapshot(); }
    src = `${still.fileUrl(item.original)}?t=${Date.now()}`;
  } else src = demoImage();
  image.crossOrigin = 'anonymous'; image.src = src; await image.decode();
  await Promise.all(Object.keys(assets).map((id) => decodeAsset(id).catch(() => {})));
  syncSource(); await loadBgImage();
  refreshIcons(); syncPanel(); updateButtons(); setTool(doc.marks.length ? 'select' : 'arrow');
  render(); fitZoom(); listenForDrops();
  if (params.get('recognize') === '1') recognize();
})();
