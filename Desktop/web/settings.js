const PAGES = [
  ['Setup', 'sparkles', '#8e8e93'],
  ['General', 'settings', '#8e8e93'], ['Shortcuts', 'command', '#5e5ce6'], ['Floating Preview', 'panel-bottom', '#30b0c7'],
  ['Screenshots', 'camera', '#34c759'], ['Screen Recording', 'video', '#ff3b30'], ['Annotate', 'pencil', '#ff9f0a'], ['Cloud', 'cloud', '#5ac8fa'], ['About', 'info', '#0a84ff']
];
const SHORTCUTS = [
  ['allInOne', 'Capture Bar'], ['area', 'Capture Area'], ['window', 'Capture Window'], ['fullscreen', 'Capture Full Screen'],
  ['previous', 'Capture Previous Area'], ['scrolling', 'Scrolling Capture'],
  ['text', 'Capture Text (OCR)'], ['record', 'Start / Stop Recording'], ['history', 'Open Capture History'], ['restore', 'Restore Last Capture']
];
let prefs, current = 'General', recordingKey = null, cloudState = { connected: false, hasToken: false }, driveState = { available: false, connected: false, email: '' };
let searchBox = null;

// Setup is a one-time guide: once finished it leaves the sidebar, and General offers to bring it back.
const setupDone = () => { try { return localStorage.getItem('stillSetupComplete') === '1'; } catch { return true; } };
const setSetupDone = (done) => { try { if (done) localStorage.setItem('stillSetupComplete', '1'); else localStorage.removeItem('stillSetupComplete'); } catch { /* the guide simply stays available */ } };
function filterNav() {
  const query = (searchBox?.value || '').trim().toLocaleLowerCase();
  let matches = 0;
  $$('#nav button[data-page]').forEach((button) => {
    const page = button.dataset.page;
    button.hidden = (page === 'Setup' && setupDone()) || !page.toLocaleLowerCase().includes(query);
    if (!button.hidden) matches++;
  });
  const empty = $('.nav-empty'); if (empty) empty.hidden = matches > 0;
}

const set = async (patch) => { prefs = { ...prefs, ...(await still.invoke('settings:set', patch)) }; };
const group = (title, rows, hint) => [title ? el('div', { class: 'group-title' }, title) : null, el('div', { class: 'group' }, rows), hint ? el('div', { class: 'hint' }, hint) : null];
const row = (label, control) => el('div', { class: 'row' }, [el('span', {}, label), control]);
const get = (path) => path.split('.').reduce((o, k) => o?.[k], prefs);
const patchFor = (path, value) => path.split('.').reduceRight((acc, k) => ({ [k]: acc }), value);
// `off` is for a feature this desktop can't do: it shows as off whatever was saved. `disabled` only locks the switch.
const toggle = (label, path, { disabled = false, off = false, redraw = false } = {}) => row(label, el('input', { type: 'checkbox', class: 'switch', 'aria-label': label, checked: !!get(path) && !off, disabled: disabled || off,
  onchange: async (e) => { await set(patchFor(path, e.target.checked)); if (redraw) render(); } }));
const select = (label, path, options, number = false, { disabled = false } = {}) => {
  const s = el('select', { class: 'field', 'aria-label': label, disabled, onchange: (e) => set(patchFor(path, number ? Number(e.target.value) : e.target.value)) },
    options.map(([value, text]) => el('option', { value, selected: String(get(path)) === String(value) }, text)));
  return row(label, s);
};

// How new captures are named, with what the next one will be called right under it as you type.
const fileNameRow = () => {
  const preview = el('div', { class: 'hint', style: 'margin:4px 0 0' });
  const show = (pattern) => {
    const ext = prefs.imageFormat === 'jpg' ? 'jpg' : 'png';
    preview.textContent = `Next: ${StillGeometry.fileName(pattern, { width: 1440, height: 900 })}.${ext} · tokens {type} {date} {time} {n} {width} {height}`;
  };
  const input = el('input', { type: 'text', class: 'field', value: get('fileName') || StillGeometry.DEFAULT_NAME, 'aria-label': 'File name', style: 'width:260px', spellcheck: 'false',
    oninput: (e) => show(e.target.value), onchange: (e) => set({ fileName: e.target.value.trim() || StillGeometry.DEFAULT_NAME }) });
  show(input.value);
  return el('div', { class: 'row', style: 'flex-wrap:wrap' }, [el('span', {}, 'File name'), el('span', { style: 'display:grid;justify-items:end' }, [input, preview])]);
};

// Your own text over every picture the editor copies, saves or shares; empty for none.
const watermarkGroup = () => {
  const wm = get('watermark') || {};
  const on = !!String(wm.text || '').trim();
  const text = el('input', { type: 'text', class: 'field', value: wm.text || '', placeholder: 'e.g. © Your Name', 'aria-label': 'Watermark text', style: 'width:260px', maxlength: '120',
    onchange: async (e) => { await set(patchFor('watermark.text', e.target.value.trim())); render(); } });
  return group('Watermark', [
    row('Text', text),
    select('Position', 'watermark.position', [['bottomRight', 'Bottom right'], ['bottomLeft', 'Bottom left'], ['topRight', 'Top right'], ['topLeft', 'Top left'], ['center', 'Centre']], false, { disabled: !on }),
    select('Size', 'watermark.size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']], false, { disabled: !on }),
    select('Opacity', 'watermark.opacity', [[1, '100%'], [0.7, '70%'], [0.5, '50%'], [0.3, '30%']], true, { disabled: !on })
  ], on ? 'Added to pictures you copy, save or share from the editor. The stamp button in the editor leaves it off one picture.' : 'Type some text to add it to pictures you copy, save or share from the editor.');
};

// High, Balanced, Smaller File, a named preset, or a bitrate you choose. A bitrate is saved as the Mac's
// "bitrate:N" tag, and presets as the Mac keeps them: a name and megabits, 1 to 100.
const mbit = (value) => Math.min(100, Math.max(1, Number(value) || 12));
const bitrateTag = (megabits) => `bitrate:${Math.round(mbit(megabits) * 1e6)}`;
const presets = () => (Array.isArray(get('recording.bitratePresets')) ? get('recording.bitratePresets') : []).filter((p) => p && String(p.name || '').trim() && Number(p.megabits) > 0);
const savePresets = async (list) => { await set(patchFor('recording.bitratePresets', list)); render(); };
const qualityRow = () => {
  const saved = String(get('recording.quality') || 'high'), chosen = saved.startsWith('bitrate:');
  const mbps = chosen ? Number(saved.slice(8)) / 1e6 : 12;
  const preset = chosen ? presets().find((p) => bitrateTag(p.megabits) === saved) : null;
  const current = !chosen ? saved : preset ? saved : 'custom';
  const options = [['high', 'High'], ['balanced', 'Balanced'], ['compact', 'Smaller File'],
    ...presets().map((p) => [bitrateTag(p.megabits), `${p.name} (${mbit(p.megabits)} Mbps)`]), ['custom', 'Custom bitrate']];
  const choice = el('select', { class: 'field', 'aria-label': 'Quality', onchange: async (e) => { await set(patchFor('recording.quality', e.target.value === 'custom' ? bitrateTag(mbps) : e.target.value)); render(); } },
    options.map(([value, text]) => el('option', { value, selected: current === value }, text)));
  if (current !== 'custom') return row('Quality', choice);
  const name = el('input', { type: 'text', class: 'field', placeholder: 'Preset name', style: 'width:120px', 'aria-label': 'Name for this bitrate preset' });
  const amount = el('input', { type: 'number', class: 'field', min: 1, max: 100, step: 0.5, value: mbps, style: 'width:76px', 'aria-label': 'Custom bitrate in megabits per second',
    onchange: (e) => set(patchFor('recording.quality', bitrateTag(e.target.value))) });
  const keep = el('button', { class: 'btn', title: 'Keep this bitrate under Quality with a name', onclick: async () => {
    const label = name.value.trim(); if (!label) { name.focus(); return; }
    await savePresets([...presets(), { name: label, megabits: mbit(amount.value) }]);
  } }, 'Add Preset');
  return row('Quality', el('span', { style: 'display:inline-flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:flex-end' }, [choice, amount, el('span', {}, 'Mbps'), name, keep]));
};
// The saved presets, each with a way to remove it. Nothing to show until there's one.
const presetsGroup = () => (presets().length ? group('Bitrate presets', presets().map((p, i) => row(`${p.name} · ${mbit(p.megabits)} Mbps`,
  el('button', { class: 'btn plain', onclick: () => savePresets(presets().filter((_, k) => k !== i)) }, 'Remove'))),
  'Presets appear under Quality. A recording made with one keeps its bitrate if the preset is removed later.') : null);

function render() {
  filterNav();
  $$('#nav button[data-page]').forEach((b) => {
    const active = b.dataset.page === current;
    b.classList.toggle('active', active);
    if (active) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  $('#pageTitle').textContent = current;
  const c = $('#content'); c.replaceChildren(...pages[current]().flat().filter(Boolean)); refreshIcons();
}

const pages = {
  Setup: () => [
    el('h2', { style: 'font-size:30px;margin:12px 0' }, 'Your first capture starts here.'),
    el('p', { class: 'hint' }, 'Start with a screenshot. Camera, microphone and cloud setup can wait until you need them.'),
    group('01 · Capture', [
      row('Choose an area, or hold Space to select a window.', el('button', { class: 'btn primary', onclick: () => still.send('capture', 'area') }, 'Try Capture Area'))
    ], prefs.wayland ? 'Your desktop will ask which screen or window to share. Choose it in the system picker each time it appears.' : 'Drag over the area you want, then release. Your capture appears in a floating preview.'),
    group('02 · Shortcuts', [
      row('Choose keys that are comfortable for you.', el('button', { class: 'btn', onclick: () => { current = 'Shortcuts'; render(); } }, 'Set Shortcuts'))
    ], prefs.wayland ? 'If a global shortcut is unavailable, add it in your desktop’s Keyboard settings using: still --capture=area. The tray menu also works.' : 'If another app already uses a shortcut, Still will flag it. Capture is always available from the tray menu.'),
    group('03 · Make it yours', [
      row('Try drawing, text and export without capturing anything.', el('button', { class: 'btn', onclick: () => still.send('open:demo') }, 'Explore the Editor')),
      row('Screenshots stay on your computer unless you upload them.', el('span', {}, 'Cloud is optional'))
    ]),
    el('div', { style: 'display:flex;justify-content:flex-end;margin-top:22px' }, [el('button', { class: 'btn primary', onclick: () => { setSetupDone(true); current = 'General'; render(); } }, 'Finish Setup')])
  ],
  General: () => [
    group('App', [
      toggle('Launch at login', 'launchAtLogin'),
      toggle('Check for updates automatically', 'autoUpdate'),
      select('Appearance', 'theme', [['system', 'System Default'], ['dark', 'Dark'], ['light', 'Light']])
    ]),
    group('Sounds', [toggle('Play sounds', 'playSounds')]),
    group('Setup', [row('Walk through the first-capture guide again.', el('button', { class: 'btn', onclick: () => { setSetupDone(false); current = 'Setup'; render(); } }, 'Open Setup Assistant…'))]),
    group('Export', [row('Export location', el('div', { style: 'display:flex;gap:8px;align-items:center' }, [
      el('span', { style: 'color:var(--text-2);max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap' }, prefs.exportFolder || 'Documents › Still'),
      el('button', { class: 'btn', onclick: async () => { if (await still.invoke('settings:chooseFolder')) { prefs = await still.invoke('settings:get'); render(); } } }, 'Choose…')
    ]))], 'Save actions from Floating Preview, the editor and After Capture use this folder.'),
    group('After Capture', [
      toggle('Show Floating Preview', 'afterCapture.quickAccess'), toggle('Copy to clipboard', 'afterCapture.copy'),
      toggle('Save to export location', 'afterCapture.save'), toggle('Open Annotate tool', 'afterCapture.annotate')
    ]),
    group('After Recording', [toggle('Show Floating Preview', 'afterRecording.quickAccess'), toggle('Save to export location', 'afterRecording.save')]),
    group('Capture History', [select('Keep history', 'historyDays', [[0, 'Forever'], [1, '1 day'], [3, '3 days'], [7, '1 week'], [30, '1 month'], [90, '3 months']], true)],
      'Older captures are deleted for good. Starred captures are always kept.'),
    el('div', { style: 'display:flex;gap:8px;margin-top:18px' }, [
      el('button', { class: 'btn', onclick: () => still.send('capture', 'allInOne') }, 'Capture Bar'),
      el('button', { class: 'btn', onclick: () => still.send('open:history') }, 'Capture History'),
      el('div', { class: 'spacer', style: 'flex:1' }),
      el('button', { class: 'btn', onclick: () => still.send('open:demo') }, 'Try Annotate')
    ])
  ],
  Shortcuts: () => [
    group(null, SHORTCUTS.map(([key, label]) => row(label, shortcutField(key)))),
    el('div', { class: 'hint' }, 'Click a shortcut, then press the new keys. Backspace clears it, Esc cancels. In the capture overlay, hold Space to capture a window.'),
    prefs.wayland ? el('div', { class: 'hint warning' }, 'On Wayland, global shortcuts may need to be added in your desktop’s keyboard settings (run “still --capture=area”).') : null,
    el('div', { style: 'display:flex;justify-content:flex-end;margin-top:14px' }, [el('button', { class: 'btn', onclick: async () => { await still.invoke('settings:reset', 'shortcuts'); prefs = await still.invoke('settings:get'); render(); } }, 'Reset Defaults')])
  ],
  'Floating Preview': () => [
    group('Floating Preview', [
      select('Position', 'quickAccess.side', [['left', 'Bottom Left'], ['right', 'Bottom Right']]),
      select('Size', 'quickAccess.size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']]),
      toggle('Close automatically', 'quickAccess.autoClose'),
      select('Close after', 'quickAccess.closeAfter', [[5, '5 seconds'], [10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute']], true)
    ], 'Hover a preview to keep it open. Drag it into any app, or double-click to annotate.')
  ],
  Screenshots: () => [
    group('Screenshots', [
      fileNameRow(),
      select('Image format', 'imageFormat', [['png', 'PNG'], ['jpg', 'JPEG']]),
      select('JPEG quality', 'jpegQuality', [[100, 'Maximum'], [90, 'High'], [75, 'Medium'], [60, 'Low']], true)
    ]),
    watermarkGroup(),
    group('Selection', [
      select('Crosshair', 'crosshair', [['partial', 'Partial'], ['full', 'Full screen'], ['disabled', 'Off']]),
      toggle('Show magnifier', 'magnifier'), toggle('Remember last selection', 'rememberSelection')
    ], prefs.wayland ? 'Window selection with Space needs an X11 session. On Wayland your desktop asks which screen to share.' : 'Hold Space while selecting to capture a whole window. Arrow keys nudge the selection; Alt+arrows resize it. Scroll to zoom the magnifier.'),
    prefs.platform === 'win32' ? group('Desktop', [toggle('Hide desktop icons while capturing', 'hideDesktopIcons')], 'Your icons come back as soon as the capture ends.') : null
  ],
  'Screen Recording': () => [
    prefs.platform === 'win32' ? group('Recorder', [
      select('Record with', 'recording.engine', [['auto', 'Still (recommended)'], ['webview', 'System web engine']]),
      toggle('Cursor effects in the video editor', 'recording.cursorEffects')
    ], 'Still records the screen, the computer’s sound and the microphone itself, with no screen picker and no “sharing your screen” bar. The system web engine records instead if Still’s recorder isn’t available on this computer. With Cursor effects on, the pointer is left out of the recording and drawn by the video editor, where you can make it bigger or smooth its movement.') : null,
    group('Video', [
      select('Format', 'recording.format', [['mp4', 'MP4'], ['webm', 'WebM']]),
      qualityRow(),
      select('Frame rate', 'recording.fps', [[24, '24 fps'], [30, '30 fps'], [60, '60 fps']], true),
      select('Countdown', 'recording.countdown', [[0, 'Off'], [3, '3 seconds'], [5, '5 seconds']], true)
    ], prefs.shortcuts.record ? `Press ${StillGeometry.shortcutLabel(prefs.shortcuts.record, prefs.platform)} to stop a recording from anywhere, even when a full-screen app hides the recording controls. If MP4 can’t be encoded on this computer, Still records WebM instead.` : 'Set a Start / Stop Recording shortcut to stop a recording from anywhere, even when a full-screen app hides the recording controls.'),
    presetsGroup(),
    group('Audio', [toggle('Record microphone', 'recording.microphone'), ...(prefs.platform === 'win32' ? [toggle('Record system audio', 'recording.systemAudio')] : [])],
      prefs.platform === 'win32' ? null : 'Computer audio recording is available on Windows.'),
    group('Camera', [
      toggle('Record camera', 'recording.camera'),
      select('Size', 'recording.cameraSize', [[120, 'Small'], [180, 'Medium'], [240, 'Large'], [320, 'Extra large']], true),
      select('Shape', 'recording.cameraShape', [['circle', 'Circle'], ['rounded', 'Rounded rectangle']])
    ], `The bubble floats above your other windows and appears in the video wherever it overlaps the recorded area. Drag it to move it.${prefs.platform === 'linux' && !prefs.globalInput ? ' On Wayland your desktop decides where it sits and whether it stays on top.' : ''}`),
    group('Overlays', [
      toggle('Show clicks', 'recording.clicks', { off: !prefs.globalInput }),
      toggle('Show keystrokes', 'recording.keys', { off: !prefs.globalInput, redraw: true }),
      toggle('Show only shortcuts', 'recording.keysShortcutsOnly', { disabled: !prefs.globalInput || !get('recording.keys') })
    ], `Keys appear on screen and in the video, and Still never saves, logs or sends them. It only watches while recording. With Shortcuts only on, it reads the keyboard only while ${prefs.platform === 'win32' ? 'Ctrl, Alt or Win' : 'Ctrl, Alt or Super'} is held, so plain typing isn’t seen at all. With Shortcuts only off, everything you type appears in the recording, including passwords: Still can’t tell when you’re in a password field.`),
    prefs.globalInput ? null : el('div', { class: 'hint warning' }, 'Your desktop doesn’t let apps see clicks or keys in other windows, so these are off. They work in an X11 session.')
  ],
  Annotate: () => [
    group('Defaults', [
      row('Color', el('input', { type: 'color', value: prefs.annotate.color, style: 'width:44px;height:26px;border:0;background:none', onchange: (e) => set({ annotate: { color: e.target.value.toUpperCase() } }) })),
      select('Stroke width', 'annotate.stroke', [[2, '2 px'], [4, '4 px'], [6, '6 px'], [10, '10 px']], true),
      select('Text size', 'annotate.font', [[20, 'Small'], [28, 'Medium'], [40, 'Large']], true)
    ], 'Tool keys: V select · A arrow · R rectangle · O ellipse · L line · P pen · H highlight · T text · N step · B redact · U blur · X pixelate · S spotlight · C crop')
  ],
  Cloud: () => {
    const status = el('span', { style: 'color:var(--text-2)' }, cloudState.connected ? 'Connected' : 'Not connected');
    const endpoint = el('input', { class: 'field', style: 'width:300px', placeholder: 'https://captures.example.com', value: prefs.cloud.endpoint || '' });
    const token = el('input', { class: 'field', style: 'width:300px', type: 'password', placeholder: cloudState.hasToken ? 'Saved — leave empty to keep it' : 'Personal access token' });
    const connect = el('button', { class: 'btn primary', onclick: async () => {
      status.textContent = 'Connecting…';
      try { const name = await still.invoke('cloud:connect', endpoint.value, token.value); cloudState = { connected: true, hasToken: true }; prefs = await still.invoke('settings:get'); render(); toast(`Connected as ${name}`); }
      catch (error) { status.textContent = String(error); status.style.color = 'var(--red)'; }
    } }, 'Connect');
    const driveButton = el('button', { class: 'btn', onclick: async (event) => {
      if (driveState.connected) { await still.invoke('drive:disconnect'); }
      else { event.target.disabled = true; event.target.textContent = 'Waiting for your browser…'; try { await still.invoke('drive:connect'); } catch (error) { toast(explain(error)); } }
      driveState = await still.invoke('drive:get'); prefs = await still.invoke('settings:get'); render();
    } }, driveState.connected ? 'Disconnect' : 'Connect');
    const disconnect = el('button', { class: 'btn', onclick: async () => { await still.invoke('cloud:disconnect'); cloudState = { connected: false, hasToken: false }; prefs = await still.invoke('settings:get'); render(); } }, 'Disconnect');
    return [
      group('Upload to', [
        select('Destination', 'cloud.provider', [['still', 'Still Cloud'], ['drive', 'Google Drive'], ...(driveState.icloud ? [['icloud', 'iCloud Drive']] : [])]),
        driveState.available ? row(driveState.connected ? `Google Drive: ${driveState.email}` : 'Google Drive', driveButton) : row('Google Drive', el('span', { style: 'color:var(--text-2)' }, 'Not available in this build')),
        driveState.connected ? select('Who can open Drive links', 'cloud.driveAccess', [['link', 'Anyone with the link'], ['private', 'Only me']]) : null
      ], prefs.cloud.provider === 'icloud' ? 'Upload saves into a Still folder in iCloud Drive. iCloud has no share link, so nothing is copied to your clipboard.' : 'Files go into a Still folder in your Drive. Still can only see files it put there.'),
      group('Server', [row('Server URL', endpoint), row('Access token', token), row(status, el('div', { style: 'display:flex;gap:8px' }, [cloudState.hasToken ? disconnect : null, connect]))],
        'Run your own Still Cloud server (see Cloud/README.md in the project). Uploads only happen when you press Upload or turn on automatic upload. The token is stored in your user profile, readable only by you.'),
      group('Uploads', [
        select('Links expire after', 'cloud.expiryDays', [[1, '1 day'], [7, '7 days'], [30, '30 days'], [0, 'Never']], true),
        select('Who can open links', 'cloud.visibility', [['link', 'Anyone with the link'], ['team', 'My team'], ['private', 'Only me']]),
        toggle('Upload every screenshot automatically', 'cloud.autoUpload'),
        select('Copy link as', 'cloud.linkFormat', [['url', 'Link'], ['markdown', 'Markdown'], ['html', 'HTML']])
      ], 'After an upload, the share link is copied to your clipboard. Markdown and HTML show pictures inline in docs, issues and chats.')
    ];
  },
  About: () => [el('div', { class: 'about' }, [
    el('img', { src: 'icon.png', alt: '' }), el('b', { style: 'font-size:18px' }, 'Still'),
    el('span', { style: 'color:var(--text-2)' }, `Version ${prefs.version} for ${prefs.platform === 'win32' ? 'Windows' : 'Linux'}`),
    el('span', { style: 'color:var(--text-2);max-width:380px' }, 'Captures and text recognition stay on your computer.'),
    updateBox(),
    el('button', { class: 'btn', onclick: () => still.send('open:history') }, 'Open Capture History')
  ])]
};

let updateStatus = { state: 'idle' };
function updateText(status) {
  return ({ checking: 'Checking for updates…', available: `Still ${status.version} is available.`, downloading: `Downloading Still ${status.version || ''}… ${status.progress || 0}%`,
    current: 'Still is up to date.', error: `Couldn’t check for updates: ${status.error}`, unavailable: status.error || 'Updates are unavailable.', idle: '' })[status.state] || '';
}
function updateBox() {
  const available = updateStatus.state === 'available';
  return el('div', { style: 'display:grid;gap:8px;justify-items:center' }, [
    el('span', { style: 'color:var(--text-2)' }, updateText(updateStatus)),
    el('button', { class: `btn${available ? ' primary' : ''}`, disabled: ['checking', 'downloading', 'unavailable'].includes(updateStatus.state),
      onclick: () => still.send(available ? 'update:install' : 'update:check') }, available ? 'Install Update' : 'Check for Updates')
  ]);
}
still.on('update:status', (status) => { updateStatus = status; if (current === 'About') render(); });

function shortcutField(key) {
  const failed = (prefs.failedShortcuts || []).includes(key);
  const field = el('button', { class: `keys${failed ? ' failed' : ''}`, title: failed ? 'Another app is using this shortcut' : 'Click to record' });
  const show = async () => {
    const accel = prefs.shortcuts[key];
    field.replaceChildren();
    if (recordingKey === key) { field.append(el('span', { class: 'placeholder' }, 'Press shortcut…')); return; }
    if (!accel) { field.append(el('span', { class: 'placeholder' }, 'Record shortcut')); return; }
    const label = await still.invoke('shortcut:label', accel);
    label.split(' + ').forEach((part) => field.append(el('kbd', {}, part)));
  };
  field.onclick = () => { recordingKey = key; still.invoke('shortcuts:pause', true); render(); };
  if (recordingKey === key) field.classList.add('recording');
  show();
  return field;
}

const KEY_NAMES = { ' ': 'Space', ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right', PrintScreen: 'PrintScreen', Escape: 'Escape', Enter: 'Return', Tab: 'Tab' };
addEventListener('keydown', async (e) => {
  if (!recordingKey) return;
  e.preventDefault();
  const key = recordingKey;
  if (e.key === 'Escape') { recordingKey = null; still.invoke('shortcuts:pause', false); return render(); }
  if (e.key === 'Backspace' || e.key === 'Delete') { recordingKey = null; await set({ shortcuts: { [key]: '' } }); return render(); }
  if (['Control', 'Shift', 'Alt', 'Meta'].includes(e.key)) return;
  const main = KEY_NAMES[e.key] || (e.code.startsWith('Digit') ? e.code.slice(5) : e.code.startsWith('Key') ? e.code.slice(3) : /^F\d+$/.test(e.key) ? e.key : e.key.length === 1 ? e.key.toUpperCase() : null);
  if (!main) return;
  const parts = [];
  if (e.ctrlKey) parts.push('CommandOrControl'); if (e.altKey) parts.push('Alt'); if (e.shiftKey) parts.push('Shift'); if (e.metaKey) parts.push('Super');
  if (!parts.length && !/^F\d+$/.test(main) && main !== 'PrintScreen') return toast('Add Ctrl, Alt or Shift');
  recordingKey = null;
  await set({ shortcuts: { [key]: [...parts, main].join('+') } });
  prefs = await still.invoke('settings:get');
  const failed = prefs.failedShortcuts.includes(key);
  if (failed) toast('That shortcut is used by another app');
  render();
});

still.on('settings:page', (page) => { if (pages[page]) { current = page; render(); } });
still.on('shortcuts:status', (failed) => { if (prefs) { prefs.failedShortcuts = failed; if (current === 'Shortcuts' && !recordingKey) render(); } });

(async () => {
  prefs = await applyTheme();
  if (!setupDone()) current = 'Setup';
  updateStatus = await still.invoke('update:status');
  driveState = await still.invoke('drive:get');
  const cloud = await still.invoke('cloud:get'); cloudState = { connected: !!cloud.endpoint && cloud.hasToken, hasToken: cloud.hasToken };
  const search = el('input', { type: 'search', class: 'field settings-search', placeholder: 'Search settings', 'aria-label': 'Search settings categories', autocomplete: 'off' });
  const empty = el('p', { class: 'nav-empty', hidden: true, role: 'status' }, 'No matching settings');
  searchBox = search;
  search.addEventListener('input', filterNav);
  $('#nav').append(search);
  $('#nav').append(...PAGES.map(([name, iconName, color]) => el('button', { 'data-page': name, html: `<span class="tile" style="background:${color}">${icon(iconName)}</span>${name}`, onclick: () => { current = name; render(); } })));
  $('#nav').append(empty, el('div', { class: 'spacer' }));
  // Window buttons sit in the top-right corner, at the end of the page's title bar.
  if (prefs.platform !== 'darwin') { const header = $('header'); header.classList.add('titlebar'); addWindowControls(header); header.querySelector('.window-controls').style.marginLeft = 'auto'; }
  render();
})();
