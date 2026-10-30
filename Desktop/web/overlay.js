const G = StillGeometry;
// The functional selection colour for window outlines comes from the stylesheet, like --mono does for labels.
const SELECTION = getComputedStyle(document.documentElement).getPropertyValue('--selection').trim() || '#0a84ff';
const selectionAlpha = (alpha) => { const hex = SELECTION.replace('#', ''); const n = parseInt(hex.length === 3 ? hex.replace(/./g, '$&$&') : hex, 16); return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`; };
const canvas = $('#canvas'), ctx = canvas.getContext('2d');
const image = new Image();
let config = null, region = null, anchor = null, pointer = { x: -100, y: -100 }, hovered = null;
let windowMode = false, spaceHeld = false, purpose = 'screenshot', aspect = 0, fixed = null, shift = false;
const bounds = () => ({ x: 0, y: 0, w: config.width, h: config.height });

// The frozen screen and window frames arrive in physical pixels; the page works in CSS pixels.
let pixelScale = 1;
function init(data) {
  if (data.warm) still.send('overlay:ready');
  config = { ...data, rawWindows: data.windows || [], width: innerWidth, height: innerHeight };
  scaleWindows();
  purpose = data.purpose === 'record' ? 'record' : data.purpose;
  if (data.primary) document.body.classList.add('primary');
  if (data.last) region = data.last;
  $('.mode[data-mode="scroll"]').hidden = !data.canScroll;
  image.onload = () => { resize(); setWindowMode(data.windowMode); updateBar(); draw(); };
  image.src = still.fileUrl(data.imagePath);
  refreshIcons();
}
// Window frames stay in physical pixels in config.rawWindows and are re-scaled whenever the page's size
// or the display scaling changes, so hover outlines keep lining up with the real windows.
function scaleWindows() {
  pixelScale = config.imageWidth / innerWidth;
  config.windows = (config.rawWindows || []).map((w) => ({ ...w, x: w.x / pixelScale, y: w.y / pixelScale, w: w.w / pixelScale, h: w.h / pixelScale }));
}
addEventListener('resize', () => { if (config) { config.width = innerWidth; config.height = innerHeight; scaleWindows(); } });
// A pre-warmed page waits hidden until a capture hands it its screen; the app falls back to a fresh page if it doesn't answer.
if (window.__STILL_PARAMS__.init) init(window.__STILL_PARAMS__.init);
else { refreshIcons(); still.on('overlay:init', init, () => still.send('overlay:ready')); }
still.on('overlay:purpose', (next) => { purpose = next; if (!StillCaptureInput.allowsWindowSelection(next)) setWindowMode(false, true); updateBar(); });
still.on('overlay:windowMode', (on) => setWindowMode(on, true));
still.on('overlay:clear', () => { if (!anchor) { pointer = { x: -100, y: -100 }; hovered = null; draw(); } });

function resize() {
  const dpr = devicePixelRatio || 1;
  canvas.width = Math.round(innerWidth * dpr); canvas.height = Math.round(innerHeight * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
addEventListener('resize', () => { if (config) { resize(); draw(); } });

function setWindowMode(on, fromOthers = false) {
  if (!config) return;
  if (on && (!config.canSelectWindows || !StillCaptureInput.allowsWindowSelection(purpose))) {
    if (on && !fromOthers) toastWindowUnavailable();
    on = false;
  }
  windowMode = on; anchor = null;
  document.body.classList.toggle('window-mode', on);
  hovered = on ? G.windowAt(config.windows, pointer) : null;
  if (!fromOthers) still.send('overlay:windowMode', on);
  updateBar(); draw();
}
function toastWindowUnavailable() {
  if (!StillCaptureInput.allowsWindowSelection(purpose)) toast('Choose Screenshot or Record to select a window');
  else toast(config.wayland ? 'Window selection needs an X11 session. Drag an area instead.' : 'No windows to select');
}

function setPurpose(next) { purpose = next; still.send('overlay:purpose', next); }

function updateBar() {
  $$('.mode[data-mode]').forEach((b) => {
    const m = b.dataset.mode;
    b.classList.toggle('active', (m === 'area' && purpose === 'screenshot' && !windowMode) || (m === 'window' && windowMode) || (m === 'text' && purpose === 'text') || (m === 'scroll' && purpose === 'scroll') || (m === 'record' && purpose === 'record'));
  });
  if (region && region.w > 0) { $('#width').value = Math.round(region.w); $('#height').value = Math.round(region.h); }
}

// ---- Drawing -------------------------------------------------------------------------------

function label(text, x, y) {
  ctx.font = `500 12px ${getComputedStyle(document.body).getPropertyValue('--mono')}`;
  const w = ctx.measureText(text).width;
  const px = Math.min(innerWidth - w - 16, Math.max(10, x + 18)), py = Math.min(innerHeight - 30, Math.max(10, y + 18));
  ctx.fillStyle = 'rgba(0,0,0,.72)'; roundRect(px - 7, py - 5, w + 14, 24, 6); ctx.fill();
  ctx.fillStyle = '#fff'; ctx.textBaseline = 'top'; ctx.fillText(text, px, py + 1);
}
function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }

function draw() {
  if (!config) return;
  ctx.clearRect(0, 0, innerWidth, innerHeight);
  ctx.drawImage(image, 0, 0, innerWidth, innerHeight);
  if (windowMode) return drawWindowMode();
  ctx.fillStyle = 'rgba(0,0,0,.28)';
  ctx.beginPath(); ctx.rect(0, 0, innerWidth, innerHeight);
  if (region && region.w > 0) ctx.rect(region.x + region.w, region.y, -region.w, region.h);
  ctx.fill('evenodd');
  if (region && region.w > 0) {
    ctx.strokeStyle = 'rgba(255,255,255,.92)'; ctx.lineWidth = 1; ctx.strokeRect(region.x + 0.5, region.y + 0.5, region.w - 1, region.h - 1);
  }
  if (config.crosshair !== 'disabled' && pointer.x >= 0) {
    ctx.strokeStyle = 'rgba(255,255,255,.85)'; ctx.lineWidth = 0.6; ctx.beginPath();
    if (config.crosshair === 'full') { ctx.moveTo(pointer.x, 0); ctx.lineTo(pointer.x, innerHeight); ctx.moveTo(0, pointer.y); ctx.lineTo(innerWidth, pointer.y); }
    else { ctx.moveTo(pointer.x - 20, pointer.y); ctx.lineTo(pointer.x + 20, pointer.y); ctx.moveTo(pointer.x, pointer.y - 20); ctx.lineTo(pointer.x, pointer.y + 20); }
    ctx.stroke();
  }
  if (pointer.x < 0) return;
  const hint = purpose === 'record' ? 'Drag to record · hold Space for a window' : purpose === 'scroll' ? 'Drag over the area you will scroll' : purpose === 'text' ? 'Drag over the text to copy' : 'Drag to select · hold Space for a window';
  label(region && region.w > 0 ? `${Math.round(region.w)} × ${Math.round(region.h)}` : hint, pointer.x, pointer.y);
  if (config.magnifier && !anchor) drawMagnifier();
}

function drawMagnifier() {
  const scale = pixelScale, size = 96, zoom = 8;
  const sx = pointer.x * scale - size / zoom / 2, sy = pointer.y * scale - size / zoom / 2;
  const x = Math.min(innerWidth - size - 10, pointer.x + 24), y = Math.max(10, pointer.y - size - 24);
  ctx.save(); roundRect(x, y, size, size, 10); ctx.clip(); ctx.imageSmoothingEnabled = false;
  ctx.drawImage(image, sx, sy, size / zoom, size / zoom, x, y, size, size);
  ctx.strokeStyle = 'rgba(255,255,255,.55)'; ctx.lineWidth = 1;
  ctx.strokeRect(x + size / 2 - zoom / 2, y + size / 2 - zoom / 2, zoom, zoom);
  ctx.restore();
  ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; roundRect(x, y, size, size, 10); ctx.stroke();
}

function drawWindowMode() {
  ctx.fillStyle = 'rgba(0,0,0,.12)'; ctx.fillRect(0, 0, innerWidth, innerHeight);
  if (hovered) {
    const r = G.intersect(hovered, bounds());
    ctx.fillStyle = selectionAlpha(0.32); ctx.fillRect(r.x, r.y, r.w, r.h);
    ctx.strokeStyle = selectionAlpha(0.85); ctx.lineWidth = 1; ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
  }
  const cam = $('#camera'); cam.style.left = `${pointer.x}px`; cam.style.top = `${pointer.y}px`;
  if (pointer.x >= 0) label(hovered ? 'Click to capture window' : 'Hold Space and move over a window', pointer.x + 6, pointer.y + 6);
}

// ---- Interaction ---------------------------------------------------------------------------

const point = (e) => ({ x: e.clientX, y: e.clientY });
const onBar = (e) => $('#bar').contains(e.target) || e.target.closest('.menu');

addEventListener('mousemove', (e) => {
  if (onBar(e)) return;
  pointer = point(e); still.send('overlay:pointer');
  if (windowMode) hovered = G.windowAt(config.windows, pointer);
  else if (anchor) {
    if (fixed) region = G.intersect({ x: pointer.x, y: pointer.y, w: fixed.w, h: fixed.h }, bounds());
    else region = G.dragRect(anchor, pointer, { aspect, square: e.shiftKey, bounds: bounds() });
    updateBar();
  }
  draw();
});

addEventListener('mousedown', (e) => {
  if (e.button !== 0 || onBar(e) || !config) return;
  pointer = point(e);
  if (windowMode) {
    hovered = G.windowAt(config.windows, pointer);
    if (hovered) finish(G.intersect(hovered, bounds()), hovered.id);
    return;
  }
  anchor = pointer; region = fixed ? G.intersect({ ...pointer, ...fixed }, bounds()) : null; draw();
});

addEventListener('mouseup', (e) => {
  if (!anchor || windowMode) return;
  anchor = null;
  if (region && region.w > 2 && region.h > 2) finish(region);
  else draw();
});

addEventListener('keyup', (e) => { if (e.code === 'Space' && spaceHeld) { spaceHeld = false; setWindowMode(false); } });

addEventListener('contextmenu', (e) => { e.preventDefault(); cancel(); });

addEventListener('keydown', (e) => {
  const action = StillCaptureInput.keyAction({ key: e.key, code: e.code, editingText: ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName), commandModifier: e.metaKey || e.ctrlKey || e.altKey, purpose });
  if (action === 'cancel') { e.preventDefault(); e.stopImmediatePropagation(); cancel(); return; }
  if (e.target.tagName === 'INPUT') { if (e.key === 'Enter') applyDimensions(); return; }
  shift = e.shiftKey;
  // Hold Space to pick a window; releasing it returns to area selection.
  if (action === 'window') { e.preventDefault(); if (!e.repeat && !anchor && !windowMode) { spaceHeld = true; setWindowMode(true); } return; }
  if (e.key === 'Enter' && region && region.w > 2) return finish(region);
  const arrows = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
  if (arrows[e.key] && !windowMode) {
    e.preventDefault();
    if (!region || region.w === 0) { const w = Math.min(640, innerWidth * 0.6), h = Math.min(360, innerHeight * 0.6); region = { x: (innerWidth - w) / 2, y: (innerHeight - h) / 2, w, h }; }
    const step = e.shiftKey ? 10 : 1, [dx, dy] = arrows[e.key];
    region = G.nudge(region, dx * step, dy * step, { resize: e.altKey, bounds: bounds() });
    updateBar(); draw(); return;
  }
  const key = e.key.toLowerCase();
  if (key === 'a') { setPurpose('screenshot'); setWindowMode(false); }
  else if (key === 'w') { if (!StillCaptureInput.allowsWindowSelection(purpose)) setPurpose('screenshot'); setWindowMode(true); }
  else if (key === 'f') still.send('overlay:fullscreen', config.displayId);
  else if (key === 'o') { setWindowMode(false); setPurpose('text'); }
  else if (key === 'v') { setWindowMode(false); setPurpose('record'); }
  else if (key === 's' && config.canScroll) { setWindowMode(false); setPurpose('scroll'); }
  else if (key === 't') still.send('overlay:timer', 5);
  updateBar();
}, true);

function finish(rect, windowId) {
  if (!StillCaptureInput.allowsWindowSelection(purpose) || !windowId) windowId = undefined;
  const r = G.normalize(rect);
  still.send('overlay:done', { displayId: config.displayId, rect: r, px: { x: r.x * pixelScale, y: r.y * pixelScale, w: r.w * pixelScale, h: r.h * pixelScale }, purpose, windowId: windowId ?? null });
}
function cancel() { still.send('overlay:cancel'); }

function applyDimensions() {
  const w = Number($('#width').value), h = Number($('#height').value);
  if (!(w > 1 && h > 1)) { fixed = null; return; }
  fixed = { w: Math.min(w, innerWidth), h: Math.min(h, innerHeight) };
  region = { x: (innerWidth - fixed.w) / 2, y: (innerHeight - fixed.h) / 2, ...fixed };
  $('#width').blur(); $('#height').blur(); draw();
  toast('Click to place, or press Enter to capture');
}

$('#bar').addEventListener('click', (e) => {
  const button = e.target.closest('[data-mode]'); if (!button) return;
  const mode = button.dataset.mode;
  if (mode === 'area') { setPurpose('screenshot'); setWindowMode(false); }
  else if (mode === 'window') { if (!StillCaptureInput.allowsWindowSelection(purpose)) setPurpose('screenshot'); setWindowMode(!windowMode); }
  else if (mode === 'fullscreen') {
    if (purpose === 'record' || purpose === 'scroll') return finish({ x: 0, y: 0, w: config.width, h: config.height });
    still.send('overlay:fullscreen', config.displayId);
  }
  else if (mode === 'timer') popupMenu(button, [3, 5, 10].map((s) => ({ label: `${s} seconds`, icon: 'timer', action: () => still.send('overlay:timer', s) })));
  else if (mode === 'text') { setWindowMode(false); setPurpose(purpose === 'text' ? 'screenshot' : 'text'); }
  else if (mode === 'record') { setWindowMode(false); setPurpose(purpose === 'record' ? 'screenshot' : 'record'); }
  else if (mode === 'scroll') { setWindowMode(false); setPurpose(purpose === 'scroll' ? 'screenshot' : 'scroll'); }
  updateBar();
});
$('#aspect').addEventListener('click', (e) => popupMenu(e.currentTarget, [['Freeform', 0], ['1:1', 1], ['4:3', 4 / 3], ['16:9', 16 / 9], ['9:16', 9 / 16]].map(([label, value]) => ({ label, action: () => { aspect = value; fixed = null; } }))));
