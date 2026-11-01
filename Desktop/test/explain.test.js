const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// explain() lives in web/common.js, which needs a page around it; this takes the function out on its own.
const source = fs.readFileSync(path.join(__dirname, '..', 'web', 'common.js'), 'utf8');
const body = source.slice(source.indexOf('function explain('), source.indexOf('function toast('));
const explain = new Function(`${body}; return explain;`)();

test('system errors become sentences that say what to do', () => {
  assert.match(explain('No space left on device (os error 28)'), /enough space on the disk/);
  assert.match(explain(new Error('There is not enough space on the disk. (os error 112)')), /enough space/);
  assert.match(explain('Permission denied (os error 13)'), /isn’t allowed to write there/);
  assert.match(explain('Access is denied. (os error 5)'), /isn’t allowed/);
  assert.match(explain('The system cannot find the file specified. (os error 2)'), /moved, renamed or deleted/);
  assert.match(explain(new Error('The file couldn’t be read (404).')), /moved, renamed or deleted/);
  assert.match(explain(new DOMException('Unable to decode audio data', 'EncodingError')), /no sound/);
  assert.equal(explain(new Error('Something specific')), 'Something specific');
  assert.equal(explain(null), 'Something went wrong.');
  assert.doesNotMatch(explain('os error 50'), /allowed/);
});
