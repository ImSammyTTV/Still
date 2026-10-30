const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../web/shared/trim');

test('In and Out stay inside the video and cannot cross', () => {
  const d = 10;
  let trim = T.full(d);
  trim = T.setIn(trim, 4, d); assert.equal(trim.start, 4);
  trim = T.setOut(trim, 6, d); assert.equal(trim.end, 6);
  assert.equal(T.setIn(trim, 9, d).start, 6 - T.MIN_LENGTH);
  assert.equal(T.setOut(trim, 1, d).end, 4 + T.MIN_LENGTH);
  assert.equal(T.setIn(trim, -3, d).start, 0);
  assert.equal(T.setOut(trim, 99, d).end, d);
});

test('a clip shorter than the minimum keeps the whole video', () => {
  const d = 0.1, trim = T.full(d);
  assert.deepEqual(T.setIn(trim, 0.05, d), { start: 0, end: d });
  assert.deepEqual(T.setOut(trim, 0.02, d), { start: 0, end: d });
});

test('a full-length trim is recognised', () => {
  assert.ok(T.isFull(T.full(8), 8));
  assert.ok(!T.isFull({ start: 0.5, end: 8 }, 8));
  assert.ok(!T.isFull({ start: 0, end: 7.5 }, 8));
  assert.equal(T.length({ start: 2, end: 3.5 }), 1.5);
});

test('positions on the trim bar map to times and back', () => {
  assert.equal(T.timeAt(50, 200, 8), 2);
  assert.equal(T.timeAt(-10, 200, 8), 0);
  assert.equal(T.timeAt(900, 200, 8), 8);
  assert.equal(T.position(2, 8), 0.25);
  assert.equal(T.position(1, 0), 0);
});

test('times show tenths and roll over correctly', () => {
  assert.equal(T.clock(0), '0:00.0');
  assert.equal(T.clock(3.44), '0:03.4');
  assert.equal(T.clock(59.96), '1:00.0');
  assert.equal(T.clock(125.5), '2:05.5');
});

test('the recorder keeps the source format when it can', () => {
  const only = (...types) => (type) => types.includes(type);
  assert.deepEqual(T.recorderType('mp4', only('video/mp4', 'video/webm')), { type: 'video/mp4', ext: 'mp4' });
  assert.deepEqual(T.recorderType('webm', only('video/mp4', 'video/webm;codecs=vp8,opus')), { type: 'video/webm;codecs=vp8,opus', ext: 'webm' });
  assert.deepEqual(T.recorderType('mp4', only('video/webm')), { type: 'video/webm', ext: 'webm' });
  assert.equal(T.recorderType('mp4', () => false).type, '');
});
