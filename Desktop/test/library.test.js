const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Library } = require('../src/main/library');
const { Settings, merge } = require('../src/main/settings');

const temp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'still-test-'));

test('library keeps the original, edits and project separately', () => {
  const dir = temp(), lib = new Library(dir);
  const item = lib.add(Buffer.from('original'), { title: 'Bug report', width: 10, height: 5 });
  lib.replaceFile(item.id, Buffer.from('edited'), 'jpg');
  lib.saveProject(item.id, { marks: [{ type: 'arrow' }] });
  const reloaded = new Library(dir);
  const again = reloaded.get(item.id);
  assert.equal(fs.readFileSync(reloaded.original(again), 'utf8'), 'original');
  assert.equal(fs.readFileSync(reloaded.file(again), 'utf8'), 'edited');
  assert.equal(again.fileName, 'capture.jpg');
  assert.deepEqual(reloaded.project(item.id).marks, [{ type: 'arrow' }]);
});

test('library search filters by kind, title and recognised text', () => {
  const lib = new Library(temp());
  lib.add(Buffer.from('a'), { title: 'Invoice' , text: 'total due' });
  lib.add(Buffer.from('b'), { title: 'Demo', kind: 'recording', ext: 'mp4' });
  assert.equal(lib.search({ query: 'due' }).length, 1);
  assert.equal(lib.search({ kind: 'recording' })[0].title, 'Demo');
  const [first] = lib.items; lib.remove(first.id);
  assert.equal(lib.items.length, 1);
});

test('settings merge nested values and survive a restart', () => {
  const dir = temp(), s = new Settings(dir);
  assert.equal(s.all.shortcuts.area, 'CommandOrControl+Shift+4');
  s.update({ shortcuts: { area: 'Alt+Shift+A' }, quickAccess: { side: 'right' } });
  const again = new Settings(dir);
  assert.equal(again.all.shortcuts.area, 'Alt+Shift+A');
  assert.equal(again.all.shortcuts.fullscreen, 'CommandOrControl+Shift+3');
  assert.equal(again.all.quickAccess.closeAfter, 15);
  assert.deepEqual(merge({ a: { b: 1, c: 2 } }, { a: { c: 3 } }), { a: { b: 1, c: 3 } });
});
