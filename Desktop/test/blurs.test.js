const test = require('node:test');
const assert = require('node:assert/strict');
const B = require('../web/shared/blurs.js');

// The same cases are in the Mac app's VideoBlurTests.
test('a new blur is three seconds long, in the middle, inside the clip', () => {
  assert.deepEqual(B.add([], 2, { start: 0, end: 4 }), [{ start: 2, end: 4, x: 0.35, y: 0.42, w: 0.3, h: 0.16 }]);
});

test('boxes stay inside the picture and come from drags either way', () => {
  assert.deepEqual(B.fromDrag({ x: 0.8, y: 0.9 }, { x: 0.6, y: 0.5 }), { x: 0.6, y: 0.5, w: 0.20000000000000007, h: 0.4 });
  assert.deepEqual(B.fit({ x: 0.9, y: 0.9, w: 0.5, h: 0.5 }), { x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
  assert.deepEqual(B.fit({ x: 0.2, y: 0.2, w: 0, h: 0.001 }), { x: 0.2, y: 0.2, w: 0.01, h: 0.01 });
  assert.deepEqual(B.fromPixels({ x: 104, y: 54, w: 192, h: 12 }, 400, 200), { x: 0.25, y: 0.25, w: 0.5, h: 0.1 });
});

test('the blurs showing at a moment', () => {
  const b = [{ start: 1, end: 2, x: 0, y: 0, w: 0.1, h: 0.1 }];
  assert.equal(B.at(b, 1.5).length, 1); assert.equal(B.at(b, 2.5).length, 0);
});
