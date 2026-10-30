const G = StillGeometry;
const stage = $('#stage'), ctx = stage.getContext('2d');
const scroller = $('#scroller');
const itemId = params.get('id') || null;

const TOOLS = [
  ['select', 'mouse-pointer-2', 'Select', 'v'], ['arrow', 'move-up-right', 'Arrow', 'a'], ['rect', 'square', 'Rectangle', 'r'],
  ['filled', 'square-dashed-bottom', 'Filled Rectangle', 'f'], ['ellipse', 'circle', 'Ellipse', 'o'], ['line', 'slash', 'Line', 'l'],
  ['pen', 'pencil', 'Pen', 'p'], ['highlight', 'highlighter', 'Highlight', 'h'], ['text', 'type', 'Text', 't'], ['step', 'list-ordered', 'Counter', 'n'],
  ['redact', 'eye-off', 'Redact', 'b'], ['blur', 'droplet', 'Blur', 'u'], ['pixelate', 'grid-3x3', 'Pixelate', 'x'], ['spotlight', 'sun-dim', 'Spotlight', 's'], ['crop', 'crop', 'Crop', 'c']
];
const COLORS = ['#FF453A', '#FF9F0A', '#FFD60A', '#32D74B', '#64D2FF', '#0A84FF', '#BF5AF2', '#FF375F', '#FFFFFF', '#1D1D1F'];
const STROKES = [2, 4, 6, 10, 16];
const GRADIENTS = {
  paper: ['#F0ECE3', '#DDD5C5'], sage: ['#D9E6C7', '#8DAE91'], midnight: ['#343F53', '#111C2B'], apricot: ['#FFD9AF', '#EAA89D'], ocean: ['#0D5AAA', '#062454'],
  sky: ['#B9DEFF', '#5E9FE8'], mint: ['#C4F3DC', '#5AADA3'], rose: ['#FFE2E6', '#DF8BB0'], coral: ['#FFB09A', '#EF565C'], lavender: ['#D8D2FA', '#8C87DD'],
  iris: ['#B59CED', '#4D3596'], dusk: ['#202255', '#C75F84'], sunrise: ['#F5CF8A', '#EE8782'], gold: ['#F5DA97', '#BC833C'], graphite: ['#4B4C50', '#1D1E20'],
  snow: ['#FFFFFF', '#ECEFF2'], forest: ['#3D8061', '#12362D'], teal: ['#83D9D3', '#1F7C91'], plum: ['#A66AA5', '#3F1B57'], crimson: ['#E58D95', '#9E2045']
};

let image = new Image(), bgImage = null, prefs = {};
let doc = { marks: [], crop: null, bg: { style: 'none', padding: 64, radius: 12, shadow: true, aspect: 0, balance: false, custom: null } };
let tool = 'arrow', color = '#FF453A', stroke = 4, zoom = 0;
let selected = null, drag = null, pendingCrop = null, history = [], future = [], dirty = false, saveTimer = null;
const isRectLike = (m) => ['rect', 'filled', 'ellipse', 'highlight', 'redact', 'blur', 'pixelate', 'spotlight'].includes(m.type);
const isSegment = (m) => m.type === 'arrow' || m.type === 'line';

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
    if (doc.bg.style === 'custom' && bgImage) drawCover(target, bgImage, L.w, L.h);
    else {
      const [a, b] = GRADIENTS[doc.bg.style] || GRADIENTS.midnight;
      const g = target.createLinearGradient(0, 0, L.w, L.h); g.addColorStop(0, a); g.addColorStop(1, b);
      target.fillStyle = g; target.fillRect(0, 0, L.w, L.h);
    }
    if (doc.bg.shadow) {
      target.save(); target.shadowColor = 'rgba(0,0,0,.35)'; target.shadowBlur = Math.max(20, L.base.w / 30); target.shadowOffsetY = Math.max(6, L.base.w / 120);
      target.fillStyle = '#000'; target.beginPath(); target.roundRect(L.ox, L.oy, L.base.w, L.base.h, doc.bg.radius); target.fill(); target.restore();
    }
    target.beginPath(); target.roundRect(L.ox, L.oy, L.base.w, L.base.h, doc.bg.radius); target.clip();
  }
  target.translate(L.ox - L.base.x, L.oy - L.base.y);
  if (L.hasBg) { target.beginPath(); target.rect(L.base.x, L.base.y, L.base.w, L.base.h); target.clip(); }
  target.drawImage(image, 0, 0);
  for (const m of doc.marks) drawMark(target, m);
  if (target === ctx && tool === 'crop') drawCropOverlay(target);
  if (handles && target === ctx && selected && tool === 'select') drawHandles(target, selected);
  target.restore();
}

function drawCover(target, img, w, h) {
  const s = Math.max(w / img.naturalWidth, h / img.naturalHeight);
  target.drawImage(img, (w - img.naturalWidth * s) / 2, (h - img.naturalHeight * s) / 2, img.naturalWidth * s, img.naturalHeight * s);
}

function drawArrowHead(t, m) {
  const angle = Math.atan2(m.y2 - m.y1, m.x2 - m.x1), size = Math.max(14, m.stroke * 4.2);
  t.beginPath();
  t.moveTo(m.x2, m.y2);
  t.lineTo(m.x2 - size * Math.cos(angle - 0.45), m.y2 - size * Math.sin(angle - 0.45));
  t.lineTo(m.x2 - size * Math.cos(angle + 0.45), m.y2 - size * Math.sin(angle + 0.45));
  t.closePath(); t.fill();
  return size;
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
    case 'arrow': {
      t.shadowColor = 'rgba(0,0,0,.25)'; t.shadowBlur = 4; t.shadowOffsetY = 1;
      const len = Math.hypot(m.x2 - m.x1, m.y2 - m.y1), angle = Math.atan2(m.y2 - m.y1, m.x2 - m.x1), head = Math.max(14, m.stroke * 4.2);
      const back = Math.min(len, head * 0.75);
      t.beginPath(); t.moveTo(m.x1, m.y1); t.lineTo(m.x2 - back * Math.cos(angle), m.y2 - back * Math.sin(angle)); t.stroke();
      drawArrowHead(t, m); break;
    }
    case 'pen': {
      const p = m.points; if (p.length < 2) break;
      t.beginPath(); t.moveTo(p[0].x, p[0].y);
      for (let i = 1; i < p.length - 1; i++) t.quadraticCurveTo(p[i].x, p[i].y, (p[i].x + p[i + 1].x) / 2, (p[i].y + p[i + 1].y) / 2);
      t.lineTo(p[p.length - 1].x, p[p.length - 1].y); t.stroke(); break;
    }
    case 'highlight': t.globalCompositeOperation = 'multiply'; t.globalAlpha = 0.45; t.fillStyle = m.color === '#FFFFFF' ? '#FFD60A' : m.color; t.fillRect(r.x, r.y, r.w, r.h); break;
    case 'text': {
      t.font = `600 ${m.size}px ${getComputedStyle(document.body).fontFamily}`; t.textBaseline = 'top';
      t.shadowColor = m.color === '#1D1D1F' ? 'rgba(255,255,255,.6)' : 'rgba(0,0,0,.45)'; t.shadowBlur = Math.max(2, m.size / 10);
      m.text.split('\n').forEach((line, i) => t.fillText(line, m.x, m.y + i * m.size * 1.2)); break;
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
  }
  t.restore();
}

function bounds(m) {
  if (m.w !== undefined) return G.normalize(m);
  if (isSegment(m)) return G.normalize({ x: m.x1, y: m.y1, w: m.x2 - m.x1, h: m.y2 - m.y1 });
  if (m.type === 'pen') {
    const xs = m.points.map((p) => p.x), ys = m.points.map((p) => p.y);
    return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  }
  if (m.type === 'text') {
    ctx.save(); ctx.font = `600 ${m.size}px ${getComputedStyle(document.body).fontFamily}`;
    const lines = m.text.split('\n'), w = Math.max(...lines.map((l) => ctx.measureText(l).width)); ctx.restore();
    return { x: m.x, y: m.y, w: Math.max(10, w), h: lines.length * m.size * 1.2 };
  }
  if (m.type === 'step') { const r = Math.max(14, m.stroke * 3.5); return { x: m.x - r, y: m.y - r, w: r * 2, h: r * 2 }; }
  return { x: 0, y: 0, w: 0, h: 0 };
}

function handlePoints(m) {
  if (isSegment(m)) return [{ x: m.x1, y: m.y1, k: 'p1' }, { x: m.x2, y: m.y2, k: 'p2' }];
  if (isRectLike(m)) { const r = G.normalize(m); return [{ x: r.x, y: r.y, k: 'nw' }, { x: r.x + r.w, y: r.y, k: 'ne' }, { x: r.x, y: r.y + r.h, k: 'sw' }, { x: r.x + r.w, y: r.y + r.h, k: 'se' }]; }
  return [];
}

function drawHandles(t, m) {
  const s = 1 / displayScale(), b = bounds(m);
  t.save(); t.setLineDash([4 * s, 3 * s]); t.strokeStyle = '#0A84FF'; t.lineWidth = 1 * s;
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
  t.restore();
}

// ---- Hit testing ------------------------------------------------------------------------------

function distanceToSegment(p, m) {
  const dx = m.x2 - m.x1, dy = m.y2 - m.y1, len = dx * dx + dy * dy || 1;
  const t = Math.max(0, Math.min(1, ((p.x - m.x1) * dx + (p.y - m.y1) * dy) / len));
  return Math.hypot(p.x - (m.x1 + t * dx), p.y - (m.y1 + t * dy));
}
function hit(p) {
  const tol = 8 / displayScale();
  for (let i = doc.marks.length - 1; i >= 0; i--) {
    const m = doc.marks[i];
    if (isSegment(m) ? distanceToSegment(p, m) < tol + m.stroke : m.type === 'pen' ? m.points.some((q) => Math.hypot(q.x - p.x, q.y - p.y) < tol + m.stroke) : G.contains(inflate(bounds(m), tol), p)) return m;
  }
  return null;
}
const inflate = (r, d) => ({ x: r.x - d, y: r.y - d, w: r.w + d * 2, h: r.h + d * 2 });
function handleAt(p, m) { const tol = 9 / displayScale(); return handlePoints(m).find((h) => Math.hypot(h.x - p.x, h.y - p.y) < tol) || null; }

// ---- History ------------------------------------------------------------------------------------

const snapshot = () => JSON.stringify(doc);
function commit() {
  history.push(lastState); if (history.length > 200) history.shift();
  future = []; lastState = snapshot(); dirty = true; scheduleSave(); updateButtons();
}
let lastState = snapshot();
function undo() { if (!history.length) return; future.push(snapshot()); doc = JSON.parse(history.pop()); lastState = snapshot(); selected = null; afterDocChange(); }
function redo() { if (!future.length) return; history.push(snapshot()); doc = JSON.parse(future.pop()); lastState = snapshot(); selected = null; afterDocChange(); }
function afterDocChange() { dirty = true; scheduleSave(); syncPanel(); updateButtons(); loadBgImage().then(render); }
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
    : (tool === 'arrow' || tool === 'line') ? { type: tool, x1: p.x, y1: p.y, x2: p.x, y2: p.y, color, stroke }
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
    resizeMark(selected, drag.orig, drag.handle, p, e.shiftKey);
  } else if (drag.kind.startsWith('crop')) {
    const full = { x: 0, y: 0, w: image.naturalWidth, h: image.naturalHeight };
    if (drag.kind === 'crop-new') pendingCrop = G.dragRect(drag.start, p, { square: e.shiftKey, bounds: full });
    else if (drag.kind === 'crop-move') pendingCrop = G.nudge(drag.orig, dx, dy, { bounds: full });
    else {
      const o = drag.orig, c = drag.corner;
      const x1 = c.includes('w') ? o.x + dx : o.x, y1 = c.includes('n') ? o.y + dy : o.y;
      const x2 = c.includes('e') ? o.x + o.w + dx : o.x + o.w, y2 = c.includes('s') ? o.y + o.h + dy : o.y + o.h;
      pendingCrop = G.intersect(G.normalize({ x: x1, y: y1, w: x2 - x1, h: y2 - y1 }), full);
    }
    $('#cropBar').classList.add('show');
  }
  render();
});

addEventListener('mouseup', () => {
  if (!drag) return;
  const d = drag; drag = null;
  if (d.kind === 'draw') {
    const b = bounds(d.mark);
    if (d.mark.type !== 'pen' && b.w < 3 && b.h < 3) { doc.marks.pop(); render(); return; }
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
  else if (m.x !== undefined) Object.assign(m, { x: o.x + dx, y: o.y + dy });
}
function resizeMark(m, o, handle, p, keepRatio) {
  if (handle === 'p1') { m.x1 = p.x; m.y1 = p.y; return; }
  if (handle === 'p2') { m.x2 = p.x; m.y2 = p.y; return; }
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
  const target = mark || { type: 'text', x: at.x, y: at.y, text: '', color, size: Math.round(prefs.annotate?.font || 28) * Math.max(1, image.naturalWidth / 1600), stroke };
  const r = stage.getBoundingClientRect(), L = layout(), s = displayScale(), main = $('main').getBoundingClientRect();
  const area = el('textarea', { class: 'text-edit', spellcheck: 'false' });
  area.value = target.text;
  Object.assign(area.style, {
    left: `${r.left - main.left + (target.x - L.base.x + L.ox) * s}px`, top: `${r.top - main.top + (target.y - L.base.y + L.oy) * s}px`,
    fontSize: `${target.size * s}px`, color: target.color, fontFamily: getComputedStyle(document.body).fontFamily, minWidth: '40px'
  });
  const grow = () => { area.style.height = 'auto'; area.style.height = `${area.scrollHeight}px`; area.style.width = 'auto'; area.style.width = `${Math.max(40, area.scrollWidth + 8)}px`; };
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
  if (tool === 'crop') { pendingCrop = doc.crop ? { ...doc.crop } : null; $('#cropBar').classList.add('show'); }
  render();
}
function applyCrop() {
  if (pendingCrop && pendingCrop.w > 4 && pendingCrop.h > 4) { doc.crop = G.normalize(pendingCrop); commit(); }
  pendingCrop = null; $('#cropBar').classList.remove('show'); tool = 'select'; setTool('select');
}
function cancelCrop() { pendingCrop = null; $('#cropBar').classList.remove('show'); }

$('#tools').append(...TOOLS.map(([id, iconName, title, key]) => el('button', { 'data-tool': id, title: `${title} (${key.toUpperCase()})`, html: icon(iconName), onclick: () => setTool(id) })));
$('#cropApply').onclick = applyCrop;
$('#cropCancel').onclick = () => setTool('select');
$('#cropReset').onclick = () => { pendingCrop = null; if (doc.crop) { doc.crop = null; commit(); } render(); };

function setColor(next) { color = next; $('#swatch').style.background = next; if (selected) { selected.color = next; commit(); render(); } still.invoke('settings:set', { annotate: { color: next } }); }
$('#color').onclick = (e) => {
  $$('.menu').forEach((m) => m.remove());
  const menu = el('div', { class: 'menu' }), grid = el('div', { class: 'palette' });
  for (const c of COLORS) grid.append(el('button', { class: c === color ? 'active' : '', style: `background:${c}`, title: c, onclick: () => { menu.remove(); setColor(c); } }));
  const custom = el('input', { type: 'color', value: color, style: 'width:100%;height:28px;border:0;background:none', oninput: (ev) => setColor(ev.target.value.toUpperCase()) });
  menu.append(grid, custom); document.body.append(menu);
  const r = e.currentTarget.getBoundingClientRect(); menu.style.left = `${r.left - 60}px`; menu.style.top = `${r.bottom + 6}px`;
  setTimeout(() => addEventListener('mousedown', function close(ev) { if (!menu.contains(ev.target)) { menu.remove(); removeEventListener('mousedown', close); } }), 0);
};
$('#stroke').onclick = (e) => popupMenu(e.currentTarget, STROKES.map((s) => ({ label: `${s} px${s === stroke ? '  ✓' : ''}`, action: () => { stroke = s; if (selected && selected.stroke !== undefined) { selected.stroke = s; commit(); render(); } still.invoke('settings:set', { annotate: { stroke: s } }); } })));
$('#undo').onclick = undo; $('#redo').onclick = redo;
$('#background').onclick = () => { $('#panel').classList.toggle('open'); if ($('#panel').classList.contains('open') && doc.bg.style === 'none') { doc.bg.style = 'midnight'; commit(); syncPanel(); } render(); setTimeout(fitZoom, 200); };

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

function flatten() {
  const prevTool = tool; tool = tool === 'crop' ? 'select' : tool;
  const out = document.createElement('canvas'), L = layout(false);
  out.width = L.w; out.height = L.h;
  const prevSel = selected; selected = null; render(out.getContext('2d'), { handles: false }); selected = prevSel; tool = prevTool;
  return out.toDataURL('image/png');
}
const project = () => ({ version: 1, ...doc });
let captureGone = false;
async function persist() {
  if (!itemId || !dirty || captureGone) return;
  dirty = false;
  // If saving fails, keep the edits marked unsaved and say so.
  try { await still.invoke('editor:save', itemId, flatten(), project()); }
  catch (e) {
    dirty = true;
    // The capture was deleted from History: stop autosaving rather than bring it back.
    if (String(e).includes('no longer exists')) { captureGone = true; toast('This capture was deleted. Use Save to keep a copy.'); return; }
    toast(`Couldn’t save your changes: ${e}`); throw e;
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
$('#save').onclick = async () => { finishTextEdit(); try { await persist(); const file = await still.invoke('editor:export', flatten(), document.title, false); if (file) toast(`Saved to ${file.split(/[\\/]/).slice(-2).join('/')}`); } catch (e) { toast(`Couldn’t save: ${e}`); } };
$('#saveAs').onclick = async () => { finishTextEdit(); try { const file = await still.invoke('editor:export', flatten(), document.title, true); if (file) toast('Saved'); } catch (e) { toast(`Couldn’t save: ${e}`); } };
$('#pin').onclick = () => still.invoke('editor:pin', flatten());
$('#upload').onclick = async () => { finishTextEdit(); toast('Uploading…'); try { await still.invoke('cloud:uploadData', flatten(), document.title); toast('Link copied'); } catch (error) { toast(String(error)); } };
$('#ocr').onclick = () => recognize();
async function recognize() {
  toast('Recognising text…');
  try { const text = (await still.invoke('editor:ocr', flatten())).trim(); if (!text) return toast('No text found'); await navigator.clipboard.writeText(text); toast('Text copied'); }
  catch (error) { toast(`Text recognition failed: ${error.message}`); }
}
dragOut($('#dragMe'), () => { finishTextEdit(); still.send('editor:drag', flatten()); });

// ---- Keyboard -----------------------------------------------------------------------------------

addEventListener('keydown', (e) => {
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
  $('#swatch').style.background = color;
  if (prefs.platform !== 'darwin') addWindowControls();
  let src;
  if (itemId) {
    const item = await still.invoke('library:get', itemId);
    if (!item) { document.body.textContent = 'This capture is no longer in the library.'; return; }
    document.title = item.title; still.send('window:setTitle', item.title);
    if (item.project) { doc = { ...doc, ...item.project, bg: { ...doc.bg, ...(item.project.bg || {}) } }; lastState = snapshot(); }
    src = `${still.fileUrl(item.original)}?t=${Date.now()}`;
  } else src = demoImage();
  image.crossOrigin = 'anonymous'; image.src = src; await image.decode();
  await loadBgImage();
  refreshIcons(); syncPanel(); updateButtons(); setTool(doc.marks.length ? 'select' : 'arrow');
  render(); fitZoom();
  if (params.get('recognize') === '1') recognize();
})();
