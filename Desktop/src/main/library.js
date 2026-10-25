const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { captureName } = require('../shared/geometry');

// Every capture lives in its own folder: the original, the latest export and an editable project.
class Library {
  constructor(dir) {
    this.dir = dir;
    this.index = path.join(dir, 'library.json');
    fs.mkdirSync(dir, { recursive: true });
    try { this.items = JSON.parse(fs.readFileSync(this.index, 'utf8')); } catch { this.items = []; }
    this.items = this.items.filter((item) => fs.existsSync(this.file(item)));
  }
  save() { fs.writeFileSync(this.index, JSON.stringify(this.items, null, 2)); }
  folder(item) { return path.join(this.dir, item.id); }
  file(item) { return path.join(this.folder(item), item.fileName); }
  original(item) { return path.join(this.folder(item), item.originalName || item.fileName); }

  add(buffer, { kind = 'screenshot', ext = 'png', title, width = 0, height = 0, text = '' } = {}) {
    const id = crypto.randomUUID();
    const item = {
      id, kind, title: title || captureName(new Date(), kind === 'recording' ? 'Still Recording' : 'Still'),
      fileName: `capture.${ext}`, originalName: `original.${ext}`, created: Date.now(), width, height, text
    };
    fs.mkdirSync(this.folder(item), { recursive: true });
    fs.writeFileSync(this.file(item), buffer);
    fs.writeFileSync(this.original(item), buffer);
    this.items.unshift(item); this.save();
    return item;
  }
  get(id) { return this.items.find((item) => item.id === id); }
  update(id, patch) {
    const item = this.get(id); if (!item) return null;
    Object.assign(item, patch); this.save(); return item;
  }
  replaceFile(id, buffer, ext) {
    const item = this.get(id); if (!item) return null;
    if (ext && `capture.${ext}` !== item.fileName) { fs.rmSync(this.file(item), { force: true }); item.fileName = `capture.${ext}`; }
    fs.writeFileSync(this.file(item), buffer); item.modified = Date.now(); this.save();
    return item;
  }
  project(id) {
    const item = this.get(id); if (!item) return null;
    try { return JSON.parse(fs.readFileSync(path.join(this.folder(item), 'project.json'), 'utf8')); } catch { return null; }
  }
  saveProject(id, project) {
    const item = this.get(id); if (!item) return;
    fs.writeFileSync(path.join(this.folder(item), 'project.json'), JSON.stringify(project));
  }
  remove(id) {
    const item = this.get(id); if (!item) return;
    fs.rmSync(this.folder(item), { recursive: true, force: true });
    this.items = this.items.filter((entry) => entry.id !== id); this.save();
  }
  search({ query = '', kind = 'all' } = {}) {
    const q = query.trim().toLowerCase();
    return this.items.filter((item) => (kind === 'all' || item.kind === kind) &&
      (!q || item.title.toLowerCase().includes(q) || (item.text || '').toLowerCase().includes(q)));
  }
}

module.exports = { Library };
