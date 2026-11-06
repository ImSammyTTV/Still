const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../web/shared/captions.js');

// The same cases are in the Mac app's VideoCaptionTests.
test('a new caption is three seconds long and stays inside the clip', () => {
  assert.deepEqual(C.add([], 2, { start: 0, end: 10 }), [{ start: 2, end: 5, text: 'Your text', position: 'bottom', size: 'medium' }]);
  assert.equal(C.add([], 9, { start: 0, end: 10 })[0].end, 10);
});

test('captions fade in and out over a quarter of a second', () => {
  const c = [{ start: 1, end: 4, text: 'Hi', position: 'bottom', size: 'medium' }, { start: 2, end: 3, text: '', position: 'top', size: 'small' }];
  assert.deepEqual(C.at(c, 0.5), []);
  assert.equal(C.at(c, 1.125)[0].alpha, 0.5);
  assert.equal(C.at(c, 2.5).length, 1, 'an empty caption shows nothing');
  assert.equal(C.at(c, 2.5)[0].alpha, 1);
});

test('size and place follow the video area', () => {
  assert.deepEqual(C.layout({ position: 'bottom', size: 'medium' }, 1920, 1080), { fontSize: 65, x: 960, y: 950.4 });
  assert.deepEqual(C.layout({ position: 'top', size: 'small' }, 640, 360), { fontSize: 16, x: 320, y: 36 });
  assert.deepEqual(C.layout({ position: 'middle', size: 'large' }, 100, 100), { fontSize: 12, x: 50, y: 50 });
});

test('a dragged caption sits where it was put, kept on the picture, and a place puts it back', () => {
  const c = { start: 0, end: 3, text: 'Hi', position: 'bottom', size: 'medium' };
  const m = C.moved(c, 0.1, -0.5, 1000, 500);
  assert.deepEqual([m.x, m.y], [0.6, 0.38]);
  assert.deepEqual(C.layout(m, 1000, 500), { fontSize: 30, x: 600, y: 190 });
  const edge = C.moved(m, 5, 5);
  assert.deepEqual([edge.x, edge.y], [0.98, 0.98]);
  assert.deepEqual(C.toPlace(edge, 'top'), { start: 0, end: 3, text: 'Hi', position: 'top', size: 'medium' });
  assert.equal(C.placed(c), false); assert.equal(C.placed(m), true);
  // The pill stays 4 px inside the video, however far it was dragged.
  assert.deepEqual(C.centre({ x: 990, y: 5 }, 100, 40, 1000, 500), { x: 946, y: 24 });
});
