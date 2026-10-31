const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../web/shared/transitions.js');

const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} ≠ ${expected}`);

// The same cases are in the Mac app's VideoTransitionTests.
test('fade opens and closes over 0.6 s of the kept part', () => {
  const clip = { start: 1, end: 11 };
  assert.deepEqual(T.at(1, clip, 'fade', 'fade'), { level: 0, scale: 1 });
  near(T.at(1.3, clip, 'fade', 'fade').level, 0.5);
  assert.deepEqual(T.at(5, clip, 'fade', 'fade'), { level: 1, scale: 1 });
  near(T.at(10.7, clip, 'fade', 'fade').level, 0.5);
  assert.deepEqual(T.at(1, clip, 'none', 'fade'), { level: 1, scale: 1 }, 'no opening');
});

test('rise grows the picture as it fades in, and only on its own side', () => {
  const clip = { start: 0, end: 10 };
  assert.deepEqual(T.at(0, clip, 'rise', 'fade'), { level: 0, scale: 0.92 });
  near(T.at(0.3, clip, 'rise', 'fade').scale, 0.96);
  assert.deepEqual(T.at(10, clip, 'rise', 'fade'), { level: 0, scale: 1 });
});

test('a short clip shortens its transitions to a third of it', () => {
  near(T.at(0.25, { start: 0, end: 1.5 }, 'fade', 'none').level, 0.5);
  assert.equal(T.active('none', 'none'), false); assert.equal(T.active('none', 'rise'), true);
});
