const test = require('node:test');
const assert = require('node:assert/strict');
const Z = require('../web/shared/zoom');

const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} ≈ ${b}`);

test('a zoom eases in, holds and eases out', () => {
  const zooms = [{ start: 1, end: 3, scale: 2, x: 0.25, y: 0.75 }];
  assert.deepEqual(Z.at(zooms, 0.5), { scale: 1, x: 0.5, y: 0.5 });
  close(Z.at(zooms, 1).scale, 1);
  close(Z.at(zooms, 1.2).scale, 1.5); // Halfway up the 0.4 s ramp.
  assert.deepEqual(Z.at(zooms, 2), { scale: 2, x: 0.25, y: 0.75 });
  close(Z.at(zooms, 3).scale, 1);
});

test('the zoomed part stays inside the video', () => {
  assert.deepEqual(Z.source(1000, 500, { scale: 2, x: 0.5, y: 0.5 }), { x: 250, y: 125, w: 500, h: 250 });
  assert.deepEqual(Z.source(1000, 500, { scale: 2, x: 0, y: 1 }), { x: 0, y: 250, w: 500, h: 250 });
  assert.deepEqual(Z.source(1000, 500, { scale: 1, x: 0.9, y: 0.1 }), { x: 0, y: 0, w: 1000, h: 500 });
});

test('Add Zoom centres on the pointer and replaces zooms it overlaps', () => {
  const pointer = [[0, 0.1, 0.1], [4.9, 0.8, 0.6], [9, 0.2, 0.2]];
  const zooms = Z.add([{ start: 4, end: 6, scale: 2, x: 0.5, y: 0.5 }, { start: 8, end: 9, scale: 2, x: 0.5, y: 0.5 }], 5, { start: 0, end: 6.5 }, pointer);
  assert.deepEqual(zooms, [{ start: 4.8, end: 6.5, scale: Z.DEFAULT_SCALE, x: 0.8, y: 0.6 }, { start: 8, end: 9, scale: 2, x: 0.5, y: 0.5 }]);
  assert.deepEqual(Z.pointerAt([], 3), { x: 0.5, y: 0.5 });
});

test('Auto Zoom makes one zoom per burst of clicks inside the trim', () => {
  const clicks = [[0.2, 0.1, 0.1], [2, 0.3, 0.3], [2.5, 0.4, 0.4], [5, 0.6, 0.6], [20, 0.9, 0.9]];
  assert.deepEqual(Z.auto(clicks, { start: 1, end: 10 }).map((z) => [z.start, z.end, z.x]), [[1.65, 3.65, 0.3], [4.65, 6.65, 0.6]]);
  // Clicks 1.9 s apart: the first zoom ends where the second begins instead of overlapping it.
  const zooms = Z.auto([[1, 0.2, 0.2], [2.9, 0.8, 0.8]], { start: 0, end: 10 });
  assert.equal(zooms[0].end, zooms[1].start);
});

test('click rings show for a moment after each click', () => {
  assert.deepEqual(Z.rings([[1, 0.5, 0.5]], 0.9), []);
  close(Z.rings([[1, 0.5, 0.5]], 1.3)[0].progress, 0.5);
  assert.deepEqual(Z.rings([[1, 0.5, 0.5]], 1 + Z.RING_LIFE), []);
});
