const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, screen, clipboard, nativeImage, nativeTheme, dialog, shell, Notification, session, desktopCapturer } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Settings } = require('./settings');
const { Library } = require('./library');
const { grabDisplays, WindowLister, isWayland } = require('./capture');
const { toPixels, intersect, captureName, shortcutLabel } = require('../shared/geometry');

if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
app.setName('Still');
if (process.platform === 'win32') app.setAppUserModelId('app.still.desktop');
if (process.platform === 'linux') app.commandLine.appendSwitch('enable-features', 'WebRTCPipeWireCapturer');

const root = path.join(__dirname, '..');
const page = (name) => path.join(root, 'renderer', `${name}.html`);
const asset = (name) => path.join(root, '..', 'build', name);
let settings, library, tray;
const windowLister = new WindowLister();
const state = { busy: false, overlays: [], grabs: [], purpose: 'screenshot', previews: [], editors: new Map(), pins: new Set(), recorder: null, hud: null, recording: null };
const singletons = {};

// ---- Windows --------------------------------------------------------------------------------

function create(name, options = {}, query = {}) {
  const win = new BrowserWindow({
    show: false, backgroundColor: nativeTheme.shouldUseDarkColors ? '#1c1c1e' : '#f2f2f7', icon: asset('icon.png'), autoHideMenuBar: true,
    ...options,
    webPreferences: { preload: path.join(root, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: false, ...(options.webPreferences || {}) }
  });
  win.removeMenu();
  win.loadFile(page(name), { query: Object.fromEntries(Object.entries(query).map(([k, v]) => [k, String(v)])) });
  return win;
}

function singleton(name, options) {
  if (singletons[name] && !singletons[name].isDestroyed()) { singletons[name].show(); singletons[name].focus(); return singletons[name]; }
  const win = create(name, options);
  win.once('ready-to-show', () => win.show());
  singletons[name] = win;
  return win;
}

const openSettings = (pageName) => {
  const win = singleton('settings', { width: 760, height: 600, minWidth: 700, minHeight: 540, title: 'Still Settings', titleBarStyle: 'hidden', titleBarOverlay: titleOverlay() });
  if (pageName) win.webContents.once('did-finish-load', () => win.webContents.send('settings:page', pageName));
};
const openHistory = () => singleton('history', { width: 980, height: 660, minWidth: 640, minHeight: 420, title: 'Capture History', titleBarStyle: 'hidden', titleBarOverlay: titleOverlay() });
const titleOverlay = () => process.platform === 'win32' ? { color: '#00000000', symbolColor: nativeTheme.shouldUseDarkColors ? '#f5f5f7' : '#1d1d1f', height: 44 } : false;

function openEditor(id, { demo = false, recognize = false } = {}) {
  const key = demo ? 'demo' : id;
  const existing = state.editors.get(key);
  if (existing && !existing.isDestroyed()) { existing.show(); existing.focus(); return; }
  const item = id && library.get(id);
  const work = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const win = create('editor', {
    width: Math.min(1180, work.width - 40), height: Math.min(800, work.height - 40), minWidth: 900, minHeight: 520,
    title: item ? item.title : 'Still — Annotate', titleBarStyle: 'hidden', titleBarOverlay: titleOverlay()
  }, { id: id || '', demo: demo ? 1 : 0, recognize: recognize ? 1 : 0 });
  win.once('ready-to-show', () => { win.show(); win.focus(); });
  win.on('closed', () => state.editors.delete(key));
  state.editors.set(key, win);
  closePreview(id);
}

// ---- Quick Access ----------------------------------------------------------------------------

const previewSize = () => ({ small: [200, 136], medium: [252, 172], large: [320, 216] })[settings.all.quickAccess.size] || [252, 172];

function layoutPreviews() {
  const work = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const [width, height] = previewSize();
  const left = settings.all.quickAccess.side !== 'right';
  let y = work.y + work.height - height - 16;
  for (const preview of state.previews) {
    if (preview.win.isDestroyed()) continue;
    preview.win.setBounds({ x: left ? work.x + 16 : work.x + work.width - width - 16, y, width, height });
    y -= height + 12;
  }
}

function showPreview(item, { sound = true } = {}) {
  const [width, height] = previewSize();
  const win = create('quick', {
    width, height, frame: false, resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false,
    skipTaskbar: true, alwaysOnTop: true, transparent: true, hasShadow: false, focusable: true, backgroundColor: '#00000000'
  }, { id: item.id, sound: sound && settings.all.playSounds ? 1 : 0 });
  win.setAlwaysOnTop(true, 'pop-up-menu');
  win.setVisibleOnAllWorkspaces(true);
  state.previews.unshift({ id: item.id, win });
  layoutPreviews();
  // Transparent windows on Windows don't always emit ready-to-show, so show once the page has loaded.
  let shown = false;
  const reveal = () => { if (shown || win.isDestroyed()) return; shown = true; win.showInactive(); win.moveTop(); };
  win.once('ready-to-show', reveal);
  win.webContents.once('did-finish-load', () => setTimeout(reveal, 30));
  setTimeout(reveal, 800);
  win.on('closed', () => { state.previews = state.previews.filter((p) => p.win !== win); layoutPreviews(); });
  while (state.previews.length > 5) state.previews.pop().win.close();
}
function closePreview(id) { for (const p of [...state.previews]) if (p.id === id && !p.win.isDestroyed()) p.win.close(); }

// ---- Selection overlay -----------------------------------------------------------------------

async function startSelection(purpose = 'screenshot', { delay = 0, windowMode = false } = {}) {
  if (state.busy || state.recording) { notify('Still', 'Finish the current capture or recording first.'); return; }
  state.busy = true; state.purpose = purpose;
  try {
    if (delay > 0) { notify('Still', `Capture starts in ${delay} seconds`); await wait(delay * 1000); }
    hidePreviews(true);
    await wait(120);
    const [grabs, windows] = await Promise.all([grabDisplays(), windowLister.list().catch(() => [])]);
    state.grabs = grabs;
    const last = settings.all.rememberSelection ? settings.all.lastSelection : null;
    state.overlays = grabs.map(({ display, image }) => {
      const b = display.bounds;
      const win = create('overlay', {
        x: b.x, y: b.y, width: b.width, height: b.height, frame: false, resizable: false, movable: false, minimizable: false, maximizable: false,
        fullscreenable: false, skipTaskbar: true, alwaysOnTop: true, enableLargerThanScreen: true, hasShadow: false, backgroundColor: '#000000',
        roundedCorners: false, thickFrame: false
      });
      win.setAlwaysOnTop(true, 'screen-saver');
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
      win.webContents.once('did-finish-load', () => {
        win.webContents.send('overlay:init', {
          displayId: display.id, purpose, windowMode: windowMode && windows.length > 0, canSelectWindows: windows.length > 0,
          wayland: isWayland(), image: `data:image/jpeg;base64,${image.toJPEG(92).toString('base64')}`, width: b.width, height: b.height, scale: display.scaleFactor,
          windows: windows.map((w) => ({ ...w, x: w.x - b.x, y: w.y - b.y })).filter((w) => w.x < b.width && w.y < b.height && w.x + w.w > 0 && w.y + w.h > 0),
          crosshair: settings.all.crosshair, magnifier: settings.all.magnifier,
          last: last && last.displayId === display.id ? last.rect : null,
          primary: display.id === screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).id
        });
        win.setBounds(b); win.show(); win.focus();
        if (process.platform === 'win32') win.setKiosk(false);
      });
      return win;
    });
  } catch (error) {
    endSelection();
    notify('Capture failed', error.message);
  }
}

function endSelection() {
  for (const win of state.overlays) if (!win.isDestroyed()) win.destroy();
  state.overlays = []; state.busy = false;
  hidePreviews(false);
}

async function finishSelection({ displayId, rect, purpose, windowId }) {
  const grab = state.grabs.find((g) => g.display.id === displayId) || state.grabs[0];
  endSelection();
  if (!grab || !rect || rect.w < 2 || rect.h < 2) return;
  if (settings.all.rememberSelection && !windowId) settings.update({ lastSelection: { displayId, rect } });
  if (purpose === 'record') return startRecording(grab.display, rect);
  let image = grab.image;
  if (!settings.all.freezeScreen && !windowId) {
    await wait(140);
    const fresh = (await grabDisplays()).find((g) => g.display.id === displayId);
    if (fresh) image = fresh.image;
  }
  const bounds = { x: 0, y: 0, w: grab.display.bounds.width, h: grab.display.bounds.height };
  const px = toPixels(intersect(rect, bounds), grab.display.scaleFactor);
  const cropped = image.crop({ x: px.x, y: px.y, width: px.w, height: px.h });
  await completeImage(cropped, { text: purpose === 'text', kind: windowId ? 'window' : 'area' });
}

async function captureFullscreen(displayId) {
  if (state.busy || state.recording) return;
  state.busy = true; hidePreviews(true);
  try {
    await wait(150);
    const grabs = await grabDisplays();
    const target = displayId ?? screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).id;
    const grab = grabs.find((g) => g.display.id === target) || grabs[0];
    await completeImage(grab.image, { kind: 'fullscreen' });
  } catch (error) { notify('Capture failed', error.message); }
  finally { state.busy = false; hidePreviews(false); }
}

function hidePreviews(hidden) {
  for (const p of state.previews) if (!p.win.isDestroyed()) hidden ? p.win.hide() : p.win.showInactive();
  for (const pin of state.pins) if (!pin.isDestroyed()) hidden ? pin.hide() : pin.showInactive();
}

// ---- After capture ---------------------------------------------------------------------------

function encode(image) {
  const format = settings.all.imageFormat === 'jpg' ? 'jpg' : 'png';
  return { ext: format, buffer: format === 'jpg' ? image.toJPEG(settings.all.jpegQuality) : image.toPNG() };
}

async function completeImage(image, { text = false } = {}) {
  const size = image.getSize();
  if (text) return recognizeText(image);
  const { buffer, ext } = encode(image);
  const item = library.add(buffer, { ext, width: size.width, height: size.height });
  const after = settings.all.afterCapture;
  if (after.copy) clipboard.writeImage(image);
  if (after.save) exportItem(item.id);
  if (after.annotate) openEditor(item.id);
  else if (after.quickAccess) showPreview(item);
  broadcast('library:changed');
  return item;
}

async function recognizeText(image) {
  try {
    const text = await ocr(image.toPNG());
    if (!text.trim()) { notify('No text found', 'Try selecting a larger area with clearer text.'); return; }
    clipboard.writeText(text.trim());
    notify('Text copied', text.trim().slice(0, 120));
  } catch (error) { notify('Text recognition failed', error.message); }
}

let ocrWorker;
async function ocr(buffer) {
  if (!ocrWorker) {
    const { createWorker } = require('tesseract.js');
    const langPath = path.dirname(require.resolve('@tesseract.js-data/eng/package.json')).replace('app.asar', 'app.asar.unpacked');
    ocrWorker = await createWorker('eng', 1, { langPath: path.join(langPath, '4.0.0_best_int'), cacheMethod: 'none', gzip: true });
  }
  const { data } = await ocrWorker.recognize(buffer);
  return data.text || '';
}

function exportFolder() {
  const folder = settings.all.exportFolder || app.getPath('desktop');
  fs.mkdirSync(folder, { recursive: true });
  return folder;
}
function uniquePath(folder, name, ext) {
  let file = path.join(folder, `${name}.${ext}`), n = 2;
  while (fs.existsSync(file)) file = path.join(folder, `${name} (${n++}).${ext}`);
  return file;
}
function exportItem(id, target) {
  const item = library.get(id); if (!item) return null;
  const ext = path.extname(item.fileName).slice(1);
  const file = target || uniquePath(exportFolder(), item.title.replace(/[\\/:*?"<>|]/g, '-'), ext);
  fs.copyFileSync(library.file(item), file);
  return file;
}

// ---- Recording -------------------------------------------------------------------------------

function startRecording(display, rect) {
  if (state.recording) return;
  const full = { x: 0, y: 0, w: display.bounds.width, h: display.bounds.height };
  state.recording = { display, rect: rect || full, started: 0, paused: false };
  const recorder = create('recorder', { width: 300, height: 200, show: false, skipTaskbar: true, webPreferences: { backgroundThrottling: false } });
  state.recorder = recorder;
  const b = display.workArea;
  const hud = create('hud', {
    width: 300, height: 52, x: Math.round(b.x + b.width / 2 - 150), y: b.y + b.height - 76, frame: false, resizable: false, skipTaskbar: true,
    alwaysOnTop: true, transparent: true, hasShadow: false, backgroundColor: '#00000000', focusable: true
  });
  hud.setAlwaysOnTop(true, 'screen-saver');
  hud.setContentProtection(true);
  hud.once('ready-to-show', () => hud.showInactive());
  state.hud = hud;
  recorder.webContents.once('did-finish-load', async () => {
    const grabs = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 1, height: 1 } });
    const source = grabs.find((s) => String(s.display_id) === String(display.id)) || grabs[0];
    state.recording.sourceId = source?.id;
    recorder.webContents.send('recorder:start', {
      rect: state.recording.rect, scale: display.scaleFactor, width: display.bounds.width, height: display.bounds.height,
      ...settings.all.recording, mime: settings.all.recording.format
    });
  });
  updateTrayRecording(true);
}

function stopRecording(cancel = false) {
  if (!state.recording) return;
  state.recording.cancelled = cancel;
  state.recorder?.webContents.send(cancel ? 'recorder:cancel' : 'recorder:stop');
}

function finishRecording(buffer, ext, duration) {
  const cancelled = state.recording?.cancelled;
  cleanupRecording();
  if (cancelled || !buffer) return;
  const item = library.add(Buffer.from(buffer), { kind: 'recording', ext, title: captureName(new Date(), 'Still Recording') });
  library.update(item.id, { duration });
  const after = settings.all.afterRecording;
  if (after.save) exportItem(item.id);
  if (after.copy) clipboard.writeBuffer?.('FileNameW', Buffer.from(`${library.file(item)}\0`, 'ucs2'));
  if (after.quickAccess) showPreview(item);
  broadcast('library:changed');
}

function cleanupRecording() {
  if (state.hud && !state.hud.isDestroyed()) state.hud.destroy();
  if (state.recorder && !state.recorder.isDestroyed()) state.recorder.destroy();
  state.hud = null; state.recorder = null; state.recording = null;
  updateTrayRecording(false);
}

// ---- Tray, shortcuts and login item ----------------------------------------------------------

const actions = {
  area: () => startSelection('screenshot'),
  allInOne: () => startSelection('screenshot'),
  fullscreen: () => captureFullscreen(),
  window: () => startSelection('screenshot', { windowMode: true }),
  record: () => state.recording ? stopRecording() : startSelection('record'),
  text: () => startSelection('text'),
  history: () => openHistory(),
  restore: () => { const item = library.items.find((i) => i.kind !== 'recording'); if (item) showPreview(item, { sound: false }); }
};
const actionTitles = { area: 'Capture Area', allInOne: 'All-In-One', fullscreen: 'Capture Fullscreen', window: 'Capture Window', record: 'Record Screen', text: 'Capture Text (OCR)', history: 'Open Capture History', restore: 'Restore Last Capture' };

function registerShortcuts() {
  globalShortcut.unregisterAll();
  const failed = [];
  for (const [action, accelerator] of Object.entries(settings.all.shortcuts)) {
    if (!accelerator || !actions[action]) continue;
    try { if (!globalShortcut.register(accelerator, actions[action])) failed.push(action); } catch { failed.push(action); }
  }
  state.failedShortcuts = failed;
  broadcast('shortcuts:status', failed);
  return failed;
}

function buildTray() {
  const s = settings.all.shortcuts;
  const item = (action, extra = {}) => ({ label: actionTitles[action], accelerator: s[action] || undefined, registerAccelerator: false, click: actions[action], ...extra });
  const displays = screen.getAllDisplays();
  const menu = Menu.buildFromTemplate([
    item('allInOne'),
    { type: 'separator' },
    item('area'), item('window'), item('fullscreen'),
    ...(displays.length > 1 ? [{ label: 'Capture Display', submenu: displays.map((d, i) => ({ label: d.label || `Display ${i + 1}`, click: () => captureFullscreen(d.id) })) }] : []),
    { label: 'Timed Capture', submenu: [3, 5, 10].map((delay) => ({ label: `Capture Area in ${delay} Seconds`, click: () => startSelection('screenshot', { delay }) })) },
    item('text'),
    { label: state.recording ? 'Stop Recording' : 'Record Screen', accelerator: s.record || undefined, registerAccelerator: false, click: actions.record },
    { type: 'separator' },
    { label: 'Open Image…', click: importImage },
    { label: 'Capture History', click: openHistory },
    { label: 'Restore Last Capture', click: actions.restore },
    { label: 'Unlock Pinned Screenshots', click: () => state.pins.forEach((p) => p.setIgnoreMouseEvents(false)) },
    { label: 'Close All Overlays', click: () => { state.previews.forEach((p) => p.win.close()); state.pins.forEach((p) => p.close()); } },
    { type: 'separator' },
    { label: 'Settings…', click: () => openSettings() },
    { label: 'Quit Still', role: 'quit' }
  ]);
  tray.setContextMenu(menu);
}

function updateTrayRecording(active) {
  if (!tray) return;
  tray.setToolTip(active ? 'Still — Recording' : 'Still');
  buildTray();
}

function applyLoginItem() {
  const enabled = !!settings.all.launchAtLogin;
  if (process.platform === 'win32') { app.setLoginItemSettings({ openAtLogin: enabled, args: ['--hidden'] }); return; }
  if (process.platform !== 'linux') return;
  const dir = path.join(os.homedir(), '.config', 'autostart'), file = path.join(dir, 'still.desktop');
  if (!enabled) { fs.rmSync(file, { force: true }); return; }
  const exec = process.env.APPIMAGE || process.execPath;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(file, `[Desktop Entry]\nType=Application\nName=Still\nExec="${exec}" --hidden\nIcon=still\nX-GNOME-Autostart-enabled=true\n`);
}

async function importImage() {
  const result = await dialog.showOpenDialog({ properties: ['openFile'], filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'] }] });
  if (result.canceled || !result.filePaths[0]) return;
  const image = nativeImage.createFromPath(result.filePaths[0]);
  if (image.isEmpty()) return notify('Still', 'That file could not be opened as an image.');
  const size = image.getSize();
  const item = library.add(image.toPNG(), { width: size.width, height: size.height, title: path.parse(result.filePaths[0]).name });
  openEditor(item.id); broadcast('library:changed');
}

// ---- Helpers ---------------------------------------------------------------------------------

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function notify(title, body) { if (Notification.isSupported()) new Notification({ title, body, icon: asset('icon.png'), silent: true }).show(); }
function broadcast(channel, ...args) { for (const win of BrowserWindow.getAllWindows()) if (!win.isDestroyed()) win.webContents.send(channel, ...args); }
const senderWindow = (event) => BrowserWindow.fromWebContents(event.sender);
const dataToImage = (dataUrl) => nativeImage.createFromDataURL(dataUrl);

function applyTheme() { nativeTheme.themeSource = settings.all.theme === 'dark' || settings.all.theme === 'light' ? settings.all.theme : 'system'; }

// ---- IPC -------------------------------------------------------------------------------------

function registerIpc() {
  ipcMain.handle('settings:get', () => ({ ...settings.all, platform: process.platform, version: app.getVersion(), failedShortcuts: state.failedShortcuts || [], wayland: isWayland() }));
  ipcMain.handle('settings:set', (_e, patch) => settings.update(patch));
  ipcMain.handle('settings:reset', (_e, key) => settings.reset(key));
  ipcMain.handle('settings:chooseFolder', async () => {
    const result = await dialog.showOpenDialog({ properties: ['openDirectory', 'createDirectory'] });
    if (result.canceled) return null;
    settings.update({ exportFolder: result.filePaths[0] }); return result.filePaths[0];
  });
  ipcMain.handle('shortcut:label', (_e, accelerator) => shortcutLabel(accelerator, process.platform));
  ipcMain.handle('shortcuts:pause', (_e, paused) => { if (paused) globalShortcut.unregisterAll(); else registerShortcuts(); });

  ipcMain.on('overlay:done', (_e, payload) => finishSelection(payload));
  ipcMain.on('overlay:cancel', () => endSelection());
  ipcMain.on('overlay:fullscreen', (_e, displayId) => { const grab = state.grabs.find((g) => g.display.id === displayId); endSelection(); if (grab) completeImage(grab.image); });
  ipcMain.on('overlay:timer', (_e, delay) => { endSelection(); setTimeout(() => startSelection(state.purpose, { delay }), 50); });
  ipcMain.on('overlay:purpose', (_e, purpose) => { state.purpose = purpose; for (const win of state.overlays) if (!win.isDestroyed()) win.webContents.send('overlay:purpose', purpose); });
  ipcMain.on('overlay:windowMode', (_e, on) => { for (const win of state.overlays) if (!win.isDestroyed()) win.webContents.send('overlay:windowMode', on); });
  ipcMain.on('overlay:pointer', (event) => { for (const win of state.overlays) if (!win.isDestroyed() && win.webContents !== event.sender) win.webContents.send('overlay:clear'); });

  ipcMain.handle('library:list', (_e, query) => library.search(query).map((item) => ({ ...item, path: library.file(item) })));
  ipcMain.handle('library:get', (_e, id) => { const item = library.get(id); return item && { ...item, path: library.file(item), original: library.original(item), project: library.project(id) }; });
  ipcMain.handle('library:rename', (_e, id, title) => { const item = library.update(id, { title }); broadcast('library:changed'); return item; });
  ipcMain.handle('library:delete', (_e, id) => { closePreview(id); library.remove(id); broadcast('library:changed'); });
  ipcMain.handle('library:copy', (_e, id) => {
    const item = library.get(id); if (!item) return;
    if (item.kind === 'recording') clipboard.writeBuffer('FileNameW', Buffer.from(`${library.file(item)}\0`, 'ucs2'));
    else clipboard.writeImage(nativeImage.createFromPath(library.file(item)));
  });
  ipcMain.handle('library:save', (_e, id) => exportItem(id));
  ipcMain.handle('library:saveAs', async (_e, id) => {
    const item = library.get(id); if (!item) return null;
    const ext = path.extname(item.fileName).slice(1);
    const result = await dialog.showSaveDialog({ defaultPath: path.join(exportFolder(), `${item.title}.${ext}`), filters: [{ name: ext.toUpperCase(), extensions: [ext] }] });
    return result.canceled ? null : exportItem(id, result.filePath);
  });
  ipcMain.handle('library:reveal', (_e, id) => { const item = library.get(id); if (item) shell.showItemInFolder(library.file(item)); });
  ipcMain.handle('library:open', (_e, id) => { const item = library.get(id); if (!item) return; if (item.kind === 'recording') shell.openPath(library.file(item)); else openEditor(id); });
  ipcMain.handle('library:pin', (_e, id) => pinItem(id));
  ipcMain.on('library:drag', (event, id) => {
    const item = library.get(id); if (!item) return;
    const icon = item.kind === 'recording' ? nativeImage.createFromPath(asset('icon.png')).resize({ width: 64 }) : nativeImage.createFromPath(library.file(item)).resize({ width: 96 });
    event.sender.startDrag({ file: library.file(item), icon });
  });

  ipcMain.handle('editor:save', (_e, id, dataUrl, project) => {
    const image = dataToImage(dataUrl);
    const { buffer, ext } = encode(image);
    let item = id && library.get(id);
    if (item) library.replaceFile(id, buffer, ext);
    else { const size = image.getSize(); item = library.add(buffer, { ext, width: size.width, height: size.height }); }
    library.saveProject(item.id, project);
    broadcast('library:changed');
    return item.id;
  });
  ipcMain.handle('editor:copy', (_e, dataUrl) => clipboard.writeImage(dataToImage(dataUrl)));
  ipcMain.handle('editor:export', async (_e, dataUrl, name, saveAs) => {
    const image = dataToImage(dataUrl);
    const { buffer, ext } = encode(image);
    let file = uniquePath(exportFolder(), (name || captureName()).replace(/[\\/:*?"<>|]/g, '-'), ext);
    if (saveAs) {
      const result = await dialog.showSaveDialog({ defaultPath: file, filters: [{ name: 'PNG', extensions: ['png'] }, { name: 'JPEG', extensions: ['jpg'] }] });
      if (result.canceled) return null;
      file = result.filePath;
      fs.writeFileSync(file, /\.jpe?g$/i.test(file) ? image.toJPEG(settings.all.jpegQuality) : image.toPNG());
      return file;
    }
    fs.writeFileSync(file, buffer); return file;
  });
  ipcMain.on('editor:drag', (event, dataUrl) => {
    const file = path.join(app.getPath('temp'), `${captureName()}.png`);
    const image = dataToImage(dataUrl); fs.writeFileSync(file, image.toPNG());
    event.sender.startDrag({ file, icon: image.resize({ width: 96 }) });
  });
  ipcMain.handle('editor:ocr', async (_e, dataUrl) => ocr(dataToImage(dataUrl).toPNG()));
  ipcMain.handle('editor:pin', (_e, dataUrl) => pinImage(dataUrl));
  ipcMain.handle('editor:openImage', async () => {
    const result = await dialog.showOpenDialog({ properties: ['openFile'], filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'] }] });
    return result.canceled ? null : nativeImage.createFromPath(result.filePaths[0]).toDataURL();
  });

  ipcMain.on('window:close', (event) => senderWindow(event)?.close());
  ipcMain.on('window:minimize', (event) => senderWindow(event)?.minimize());
  ipcMain.on('window:toggleMaximize', (event) => { const win = senderWindow(event); if (win) win.isMaximized() ? win.unmaximize() : win.maximize(); });
  ipcMain.on('window:setTitle', (event, title) => senderWindow(event)?.setTitle(title));
  ipcMain.on('preview:close', (event) => senderWindow(event)?.close());
  ipcMain.on('preview:hold', (event, held) => broadcast('preview:hold', held));
  ipcMain.on('preview:edit', (event, id) => { senderWindow(event)?.close(); openEditor(id); });
  ipcMain.on('pin:resize', (event, delta) => {
    const win = senderWindow(event); if (!win) return;
    const [w, h] = win.getSize(), ratio = h / w, next = Math.max(80, Math.round(w * (1 + delta)));
    win.setSize(next, Math.round(next * ratio));
  });
  ipcMain.on('pin:move', (event, dx, dy) => { const win = senderWindow(event); if (!win) return; const [x, y] = win.getPosition(); win.setPosition(Math.round(x + dx), Math.round(y + dy)); });
  ipcMain.on('pin:opacity', (event, value) => senderWindow(event)?.setOpacity(value));
  ipcMain.on('pin:lock', (event, locked) => senderWindow(event)?.setIgnoreMouseEvents(locked, { forward: true }));

  ipcMain.on('open:settings', (_e, pageName) => openSettings(pageName));
  ipcMain.on('open:history', () => openHistory());
  ipcMain.on('open:demo', () => openEditor(null, { demo: true }));
  ipcMain.on('capture', (_e, action) => actions[action]?.());

  ipcMain.on('recorder:started', () => { if (state.recording) state.recording.started = Date.now(); state.hud?.webContents.send('hud:started'); });
  ipcMain.on('recorder:error', (_e, message) => { cleanupRecording(); notify('Recording couldn’t start', message); });
  ipcMain.on('recorder:countdown', (_e, n) => state.hud?.webContents.send('hud:countdown', n));
  ipcMain.on('recorder:warning', (_e, message) => notify('Still', message));
  ipcMain.on('recorder:paused', (_e, paused) => state.hud?.webContents.send('hud:paused', paused));
  ipcMain.on('recorder:data', (_e, buffer, ext, duration) => finishRecording(buffer, ext, duration));
  ipcMain.on('hud:stop', () => stopRecording());
  ipcMain.on('hud:cancel', () => stopRecording(true));
  ipcMain.on('hud:pause', () => state.recorder?.webContents.send('recorder:pause'));
  ipcMain.on('hud:restart', () => { const r = state.recording; if (!r) return; stopRecording(true); setTimeout(() => startRecording(r.display, r.rect), 400); });
}

function pinItem(id) {
  const item = library.get(id); if (!item) return;
  pinImage(nativeImage.createFromPath(library.file(item)).toDataURL(), item);
}
function pinImage(dataUrl) {
  const image = dataToImage(dataUrl), size = image.getSize();
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const scale = display.scaleFactor;
  const fit = Math.min(1, (display.workArea.width * 0.6) / (size.width / scale), (display.workArea.height * 0.6) / (size.height / scale));
  const width = Math.round((size.width / scale) * fit), height = Math.round((size.height / scale) * fit);
  const file = path.join(app.getPath('temp'), `still-pin-${Date.now()}.png`);
  fs.writeFileSync(file, image.toPNG());
  const win = create('pin', {
    width, height, x: Math.round(display.workArea.x + (display.workArea.width - width) / 2), y: Math.round(display.workArea.y + (display.workArea.height - height) / 2),
    frame: false, resizable: true, skipTaskbar: true, alwaysOnTop: true, hasShadow: true, transparent: false, backgroundColor: '#000000', minWidth: 60, minHeight: 40
  }, { file });
  win.setAspectRatio(width / height);
  win.setAlwaysOnTop(true, 'floating');
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { state.pins.delete(win); fs.rmSync(file, { force: true }); });
  state.pins.add(win);
}

// ---- Startup ---------------------------------------------------------------------------------

// `still --capture area` lets desktops without global shortcut support (Wayland) bind their own keys.
function runArgs(argv) {
  // Chromium moves switch values around, so accept both `--capture=area` and `--capture area`.
  const inline = argv.find((arg) => arg.startsWith('--capture='));
  const action = inline ? inline.split('=')[1] : argv.includes('--capture') ? argv.find((arg) => actions[arg]) : null;
  if (action && actions[action]) { actions[action](); return true; }
  return false;
}
// ---- Self-test (used by CI on real Windows / Linux machines) ----------------------------------

async function selfTest(outDir) {
  const results = {}, log = (key, value) => { results[key] = value; console.log(`[self-test] ${key}: ${JSON.stringify(value)}`); };
  fs.mkdirSync(outDir, { recursive: true });
  const snap = async (name) => { try { const [g] = await grabDisplays(); fs.writeFileSync(path.join(outDir, `${name}.png`), g.image.toPNG()); } catch (error) { log(`snap-${name}`, error.message); } };
  try {
    const before = library.items.length;
    await captureFullscreen();
    await wait(1500);
    log('fullscreenAdded', library.items.length === before + 1);
    const item = library.items[0];
    const preview = state.previews[0];
    log('previewCreated', !!preview);
    log('previewVisible', !!preview && !preview.win.isDestroyed() && preview.win.isVisible());
    log('previewBounds', preview && preview.win.getBounds());
    await snap('1-after-capture');
    clipboard.clear();
    if (preview) {
      await preview.win.webContents.executeJavaScript("document.querySelector('#copy').click()");
      await wait(800);
    }
    const copied = clipboard.readImage();
    log('quickAccessCopy', !copied.isEmpty() && copied.getSize());
    clipboard.clear();
    clipboard.writeImage(nativeImage.createFromPath(library.file(item)));
    log('directCopy', !clipboard.readImage().isEmpty());
    // Area capture through the overlay pipeline
    await startSelection('screenshot');
    await wait(1500);
    log('overlayWindows', state.overlays.length);
    await snap('2-overlay');
    const display = screen.getPrimaryDisplay();
    await finishSelection({ displayId: display.id, rect: { x: 50, y: 50, w: 300, h: 200 }, purpose: 'screenshot' });
    await wait(1500);
    log('areaSize', library.items[0].width + 'x' + library.items[0].height);
    log('previewsAfterArea', state.previews.filter((p) => !p.win.isDestroyed() && p.win.isVisible()).length);
    await snap('3-after-area');
    // Editor copy
    openEditor(library.items[0].id);
    await wait(2500);
    const editor = state.editors.get(library.items[0].id);
    clipboard.clear();
    if (editor) { await editor.webContents.executeJavaScript("document.querySelector('#copy').click()"); await wait(800); }
    log('editorCopy', !clipboard.readImage().isEmpty());
    await snap('4-editor');
    log('windowList', (await windowLister.list()).length);
  } catch (error) { log('error', error.stack || error.message); }
  fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(results, null, 2));
  app.exit(0);
}

app.on('second-instance', (_event, argv) => { if (!runArgs(argv)) openSettings(); });
app.on('window-all-closed', (event) => event.preventDefault?.());
app.on('will-quit', () => { globalShortcut.unregisterAll(); windowLister.stop(); ocrWorker?.terminate(); });

app.whenReady().then(() => {
  settings = new Settings(app.getPath('userData'));
  library = new Library(path.join(app.getPath('userData'), 'Library'));
  applyTheme();
  registerIpc();
  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    const sources = await desktopCapturer.getSources({ types: ['screen'] });
    const source = sources.find((s) => s.id === state.recording?.sourceId) || sources[0];
    callback({ video: source, audio: settings.all.recording.systemAudio && process.platform === 'win32' ? 'loopback' : undefined });
  });
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => callback(['media', 'display-capture', 'notifications', 'clipboard-sanitized-write'].includes(permission)));
  tray = new Tray(nativeImage.createFromPath(asset(process.platform === 'win32' ? 'tray-small.png' : 'tray.png')).resize({ width: process.platform === 'win32' ? 16 : 22 }));
  tray.setToolTip('Still');
  tray.on('click', () => process.platform === 'win32' ? startSelection('screenshot') : tray.popUpContextMenu());
  buildTray();
  const failed = registerShortcuts();
  windowLister.start();
  applyLoginItem();
  settings.onChange((_values, patch) => {
    if (patch.shortcuts) registerShortcuts();
    if (patch.theme) applyTheme();
    if (patch.launchAtLogin !== undefined) applyLoginItem();
    if (patch.quickAccess) layoutPreviews();
    buildTray();
    broadcast('settings:changed', settings.all);
  });
  screen.on('display-added', buildTray); screen.on('display-removed', buildTray);
  const selfTestArg = process.argv.find((arg) => arg.startsWith('--self-test='));
  if (selfTestArg) { settings.update({ welcomed: true }); setTimeout(() => selfTest(selfTestArg.split('=')[1]), 1500); return; }
  if (runArgs(process.argv)) { /* launched for a single capture */ }
  else if (process.argv.includes('--editor-demo')) openEditor(null, { demo: true });
  else if (!process.argv.includes('--hidden') && !settings.all.welcomed) { settings.update({ welcomed: true }); openSettings(); }
  if (failed.length) notify('Some shortcuts are already in use', failed.map((a) => actionTitles[a]).join(', ') + '. Choose different ones in Settings → Shortcuts.');
});
