const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../web/shared/cursor');

const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} ≈ ${b}`);
const path = [[1, 0.2, 0.2], [2, 0.6, 0.4], [3, 0.6, 0.4]];

test('the pointer follows its path in straight lines and waits at the ends', () => {
  assert.equal(C.raw([], 1), null);
  assert.deepEqual(C.raw(path, 0), { x: 0.2, y: 0.2 });
  const half = C.raw(path, 1.5); close(half.x, 0.4); close(half.y, 0.3);
  assert.deepEqual(C.raw(path, 9), { x: 0.6, y: 0.4 });
});

test('smoothing averages a short stretch, so a still pointer stays put', () => {
  const still = C.at(path, 2.8, true); close(still.x, 0.6); close(still.y, 0.4);
  const moving = C.at(path, 1.5, true); close(moving.x, 0.4); // A straight stretch averages to the same place.
  const corner = C.at(path, 2, true); assert.ok(corner.x < 0.6 && corner.x > 0.5, String(corner.x)); // Corners are rounded off.
  assert.equal(C.at([], 1, true), null);
});
