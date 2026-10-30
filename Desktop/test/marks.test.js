const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../web/shared/marks');

test('keys stay for a moment, then go', () => {
  const shown = M.visibleKeys([], 'Ctrl + C', 1000);
  assert.deepEqual(shown.map((k) => k.text), ['Ctrl + C']);
  assert.equal(M.visibleKeys(shown, null, 1000 + M.KEY_LIFE - 1).length, 1);
  assert.equal(M.visibleKeys(shown, null, 1000 + M.KEY_LIFE).length, 0);
});

test('fast typing keeps only the newest keys', () => {
  let shown = [];
  for (let i = 0; i < 10; i++) shown = M.visibleKeys(shown, String(i), 1000 + i);
  assert.deepEqual(shown.map((k) => k.text), ['4', '5', '6', '7', '8', '9']);
});

test('every camera failure explains itself and says the recording carries on', () => {
  const says = (name) => M.cameraMessage({ name });
  assert.match(says('NotAllowedError'), /privacy settings/);
  assert.match(says('NotFoundError'), /No camera/);
  assert.match(says('NotReadableError'), /busy/);
  assert.match(says('AbortError'), /busy/);
  assert.match(says('TimeoutError'), /in time/);
  assert.match(says('UnsupportedError'), /web engine/);
  for (const error of [null, undefined, {}, { name: 'SomethingNew' }, new TypeError('x')]) assert.match(M.cameraMessage(error), /could not be started/);
  for (const name of ['NotAllowedError', 'NotFoundError', 'NotReadableError', 'EndedError', '']) assert.match(says(name), /recording continues/);
});
