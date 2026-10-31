const test = require('node:test');
const assert = require('node:assert/strict');
const B = require('../web/shared/backdrop');

test('a video frame grows by its padding on every side and stays even', () => {
  const F = B.videoFrame(1001, 600, { style: 'ocean', padding: 10, radius: 2 });
  assert.equal(F.x, (F.w - 1001) / 2);
  assert.equal(F.w % 2, 0); assert.equal(F.h % 2, 0);
  assert.equal(F.h, 600 + 2 * 60); // 10% of the shorter side, each side.
  assert.equal(F.radius, 12);
});

test('no background means the video as it is, with square corners', () => {
  assert.deepEqual(B.videoFrame(640, 360, { style: 'none', padding: 10, radius: 4 }), { w: 640, h: 360, x: 0, y: 0, width: 640, height: 360, radius: 0 });
});
