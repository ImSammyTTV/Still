const { app, Notification } = require('electron');

// Checks GitHub Releases for a newer Still, downloads it in the background and installs it on quit
// (or straight away from "Restart to Update"). Only runs in packaged builds.
class Updater {
  constructor({ settings, onChange }) {
    this.settings = settings; this.onChange = onChange || (() => {});
    this.status = { state: 'idle', version: null, progress: 0, error: null };
    this.updater = null;
  }
  start() {
    if (!app.isPackaged) { this.set({ state: 'unavailable', error: 'Updates work in installed builds.' }); return; }
    try { this.updater = require('electron-updater').autoUpdater; }
    catch (error) { this.set({ state: 'unavailable', error: error.message }); return; }
    const u = this.updater;
    u.autoDownload = true; u.autoInstallOnAppQuit = true; u.allowPrerelease = false;
    u.on('checking-for-update', () => this.set({ state: 'checking', error: null }));
    u.on('update-available', (info) => this.set({ state: 'downloading', version: info.version, progress: 0 }));
    u.on('update-not-available', () => this.set({ state: 'current' }));
    u.on('download-progress', (p) => this.set({ state: 'downloading', progress: Math.round(p.percent) }));
    u.on('update-downloaded', (info) => {
      this.set({ state: 'ready', version: info.version, progress: 100 });
      if (Notification.isSupported()) {
        const note = new Notification({ title: `Still ${info.version} is ready`, body: 'Click to restart and update, or it installs when you quit.' });
        note.on('click', () => this.install()); note.show();
      }
    });
    u.on('error', (error) => this.set({ state: 'error', error: friendly(error) }));
    if (this.settings.all.autoUpdate !== false) {
      setTimeout(() => this.check(), 10_000);
      this.timer = setInterval(() => this.check(), 6 * 60 * 60 * 1000);
    }
  }
  check() {
    if (!this.updater || ['checking', 'downloading', 'ready'].includes(this.status.state)) return;
    this.updater.checkForUpdates().catch((error) => this.set({ state: 'error', error: friendly(error) }));
  }
  install() { if (this.status.state === 'ready') setImmediate(() => this.updater.quitAndInstall(false, true)); }
  set(patch) { this.status = { ...this.status, ...patch }; this.onChange(this.status); }
}

function friendly(error) {
  const text = String(error && (error.message || error));
  if (/ENOTFOUND|ETIMEDOUT|ECONNREFUSED|net::/.test(text)) return 'No internet connection.';
  if (/latest.*\.yml|404/.test(text)) return 'No update information found for this version.';
  if (/not supported|tar\.gz/i.test(text)) return 'This package type updates through your package manager or a new download.';
  return text.split('\n')[0].slice(0, 160);
}

module.exports = { Updater };
