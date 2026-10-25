// Small helpers every Still window shares.
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const params = new URLSearchParams(Object.entries(window.__STILL_PARAMS__ || {}).filter(([, v]) => typeof v !== 'object').map(([k, v]) => [k, String(v)]));

const icon = (name, size) => `<i data-lucide="${name}"${size ? ` style="width:${size}px;height:${size}px"` : ''}></i>`;
const refreshIcons = () => window.lucide && window.lucide.createIcons({ attrs: { 'stroke-width': 1.8 } });

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'class') node.className = value;
    else if (key === 'html') node.innerHTML = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of [].concat(children)) if (child != null) node.append(child.nodeType ? child : document.createTextNode(child));
  return node;
}

let toastTimer;
function toast(text) {
  let node = $('.toast');
  if (!node) { node = el('div', { class: 'toast' }); document.body.append(node); }
  node.textContent = text; node.classList.add('show');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => node.classList.remove('show'), 1800);
}

function popupMenu(anchor, items) {
  $$('.menu').forEach((m) => m.remove());
  const menu = el('div', { class: 'menu' });
  for (const item of items) {
    if (item === '-') { menu.append(el('hr')); continue; }
    menu.append(el('button', { html: `${item.icon ? icon(item.icon) : ''}<span>${item.label}</span>`, onclick: () => { menu.remove(); item.action(); } }));
  }
  document.body.append(menu); refreshIcons();
  const r = anchor.getBoundingClientRect ? anchor.getBoundingClientRect() : { left: anchor.x, bottom: anchor.y, top: anchor.y };
  const m = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(r.left, innerWidth - m.width - 8)}px`;
  menu.style.top = `${r.bottom + m.height + 6 > innerHeight ? r.top - m.height - 6 : r.bottom + 6}px`;
  setTimeout(() => addEventListener('mousedown', function close(e) { if (!menu.contains(e.target)) { menu.remove(); removeEventListener('mousedown', close); } }), 0);
}

async function applyTheme() {
  const prefs = await still.invoke('settings:get');
  document.documentElement.dataset.theme = prefs.theme === 'system' ? '' : prefs.theme;
  document.body.classList.add(prefs.platform);
  return prefs;
}
still.on('settings:changed', (prefs) => { document.documentElement.dataset.theme = prefs.theme === 'system' ? '' : prefs.theme; });

// A short shutter sound, synthesised so there is no audio file to ship.
function shutter() {
  try {
    const ctx = new AudioContext(), now = ctx.currentTime;
    for (const [start, freq] of [[0, 2200], [0.07, 1500]]) {
      const len = 0.05, buffer = ctx.createBuffer(1, ctx.sampleRate * len, ctx.sampleRate), data = buffer.getChannelData(0);
      for (let i = 0; i < data.length; i++) data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / data.length, 3);
      const src = ctx.createBufferSource(), filter = ctx.createBiquadFilter(), gain = ctx.createGain();
      src.buffer = buffer; filter.type = 'bandpass'; filter.frequency.value = freq; gain.gain.value = 0.5;
      src.connect(filter).connect(gain).connect(ctx.destination); src.start(now + start);
    }
    setTimeout(() => ctx.close(), 400);
  } catch { /* audio is optional */ }
}

// Windows are frameless, so they get their own minimise / maximise / close buttons.
function addWindowControls() {
  const box = el('div', { class: 'segmented no-drag', style: 'margin-left:8px' }, [
    el('button', { title: 'Minimise', html: icon('minus'), onclick: () => still.send('window:minimize') }),
    el('button', { title: 'Maximise', html: icon('square', 13), onclick: () => still.send('window:toggleMaximize') }),
    el('button', { title: 'Close', html: icon('x'), onclick: () => still.send('window:close') })
  ]);
  $('.titlebar').append(box);
  refreshIcons();
}

// Tauri switches off the web page's own drag and drop on Windows, so start a native file drag
// once the pointer has moved a few pixels with the button held.
function dragOut(element, start) {
  element.addEventListener('mousedown', (down) => {
    if (down.button !== 0 || down.target.closest('button')) return;
    const move = (e) => {
      if (Math.hypot(e.clientX - down.clientX, e.clientY - down.clientY) < 4) return;
      removeEventListener('mousemove', move); removeEventListener('mouseup', up);
      start();
    };
    const up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
    addEventListener('mousemove', move); addEventListener('mouseup', up);
  });
}
