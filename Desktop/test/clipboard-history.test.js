const test = require('node:test');
const assert = require('node:assert/strict');
const clip = require('../web/shared/clipboard-history.js');

const text = (t, extra = {}) => ({ kind: 'text', text: t, ...extra });

test('titles read like the Mac menu', () => {
  assert.equal(clip.title(text('Hello world\nsecond line')), 'Hello world');
  assert.equal(clip.title(text('\n\n   Indented after blank lines  ')), 'Indented after blank lines');
  assert.equal(clip.title(text('   \n')), '(blank text)');
  assert.equal(clip.title(text('x'.repeat(60))), 'x'.repeat(60));
  assert.equal(clip.title(text('y'.repeat(61))), `${'y'.repeat(57)}…`);
  assert.equal(clip.title({ kind: 'image', width: 1440, height: 900 }), 'Image 1440 × 900');
  assert.equal(clip.title({ kind: 'files', files: ['C:\\Users\\me\\report.pdf'] }), 'report.pdf');
  assert.equal(clip.title({ kind: 'files', files: ['/home/me/a.png', '/home/me/b.png', '/home/me/c.png'] }), 'a.png + 2 more');
  assert.equal(clip.title({ kind: 'files', files: [] }), 'Files');
});

test('long titles are cut by character, not in the middle of one', () => {
  const emoji = '😀'.repeat(70);
  assert.equal(clip.title(text(emoji)), `${'😀'.repeat(57)}…`);
});

test('the line under the title says what it is and how long ago', () => {
  const now = Date.UTC(2026, 10, 22, 12);
  assert.equal(clip.detail(text('a', { date: now - 5000 }), now), 'Text · Just now');
  assert.equal(clip.detail({ kind: 'image', date: now - 5 * 60e3 }, now), 'Image · 5 min ago');
  assert.equal(clip.detail({ kind: 'files', files: ['a'], date: now - 3 * 3600e3 }, now), 'File · 3 hr ago');
  assert.equal(clip.detail({ kind: 'files', files: ['a', 'b'], date: now - 30 * 3600e3 }, now), '2 files · Yesterday');
  assert.equal(clip.age(now - 4 * 86400e3, now), '4 days ago');
  assert.equal(clip.age(now + 1000, now), 'Just now');
});

test('a search finds every word anywhere in the entry, ignoring case', () => {
  const items = [text('Meeting notes for Tuesday'), text('Invoice 2041 paid'), { kind: 'image', width: 800, height: 600 },
    { kind: 'files', files: ['/home/me/Budget 2026.xlsx'] }];
  const found = (query) => clip.filter(items, query).map(clip.title);
  assert.deepEqual(found(''), clip.filter(items, '   ').map(clip.title));
  assert.equal(found('').length, 4);
  assert.deepEqual(found('tuesday meeting'), ['Meeting notes for Tuesday']);
  assert.deepEqual(found('2041'), ['Invoice 2041 paid']);
  assert.deepEqual(found('image'), ['Image 800 × 600']);
  assert.deepEqual(found('800×600'), ['Image 800 × 600']);
  assert.deepEqual(found('budget'), ['Budget 2026.xlsx']);
  assert.deepEqual(found('nothing like this'), []);
});

test('number keys pick the newest ten, 1 first and 0 tenth', () => {
  assert.equal(clip.numberIndex('1'), 0);
  assert.equal(clip.numberIndex('9'), 8);
  assert.equal(clip.numberIndex('0'), 9);
  assert.equal(clip.numberIndex('a'), -1);
  assert.equal(clip.numberIndex('10'), -1);
  assert.deepEqual([0, 8, 9, 10].map(clip.numberKey), ['1', '9', '0', '']);
});

test('the highlight stays within the list', () => {
  assert.equal(clip.step(0, -1, 5), 0);
  assert.equal(clip.step(4, 1, 5), 4);
  assert.equal(clip.step(2, 1, 5), 3);
  assert.equal(clip.step(-1, 1, 5), 0);
  assert.equal(clip.step(-1, -1, 5), 4);
  assert.equal(clip.step(1, 10, 5), 4);
  assert.equal(clip.step(0, 1, 0), -1);
});

test('Remember offers the Mac’s choices', () => {
  assert.deepEqual(clip.LIMITS, [25, 50, 100, 200]);
});
