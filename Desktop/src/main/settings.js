const fs = require('fs');
const path = require('path');

const defaults = {
  theme: 'system',
  launchAtLogin: false,
  autoUpdate: true,
  playSounds: true,
  exportFolder: '',
  imageFormat: 'png',
  jpegQuality: 90,
  afterCapture: { quickAccess: true, copy: true, save: false, annotate: false },
  afterRecording: { quickAccess: true, copy: false, save: true },
  quickAccess: { side: 'left', size: 'medium', autoClose: true, closeAfter: 15 },
  crosshair: 'partial',
  magnifier: true,
  freezeScreen: true,
  rememberSelection: false,
  recording: { fps: 30, format: 'mp4', microphone: false, systemAudio: false, showCursor: true, countdown: 3 },
  annotate: { color: '#FF453A', stroke: 4, font: 28 },
  shortcuts: {
    area: 'CommandOrControl+Shift+4',
    allInOne: 'CommandOrControl+Shift+5',
    fullscreen: 'CommandOrControl+Shift+3',
    window: 'CommandOrControl+Alt+Shift+4',
    record: 'CommandOrControl+Shift+6',
    text: 'CommandOrControl+Shift+2',
    history: '',
    restore: ''
  }
};

const merge = (base, saved) => {
  const out = Array.isArray(base) ? [...base] : { ...base };
  for (const [key, value] of Object.entries(saved || {})) {
    out[key] = value && typeof value === 'object' && !Array.isArray(value) && base[key] && typeof base[key] === 'object'
      ? merge(base[key], value) : value;
  }
  return out;
};

class Settings {
  constructor(dir) {
    this.file = path.join(dir, 'settings.json');
    let saved = {};
    try { saved = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { /* first launch */ }
    this.values = merge(defaults, saved);
    this.listeners = new Set();
  }
  get all() { return this.values; }
  update(patch) {
    this.values = merge(this.values, patch);
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.values, null, 2));
    for (const listener of this.listeners) listener(this.values, patch);
    return this.values;
  }
  reset(key) { return this.update({ [key]: defaults[key] }); }
  onChange(listener) { this.listeners.add(listener); }
}

module.exports = { Settings, defaults, merge };
