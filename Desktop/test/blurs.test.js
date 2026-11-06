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

// ---- Moving, fading and see-through blurs (the same cases are in the Mac app's VideoBlurTests) ----
const near = (a, b) => Object.keys(b).forEach((k) => assert.ok(Math.abs(a[k] - b[k]) < 1e-9, `${k}: ${a[k]} vs ${b[k]}`));

test('a still blur is its own box; a keyed one glides between keys and holds at the ends', () => {
  const still = { start: 0, end: 10, x: 0.1, y: 0.2, w: 0.3, h: 0.1 };
  near(B.boxAt(still, 5), { x: 0.1, y: 0.2, w: 0.3, h: 0.1 });
  const moving = { ...still, keys: [{ t: 2, x: 0.1, y: 0.2, w: 0.2, h: 0.1 }, { t: 6, x: 0.5, y: 0.6, w: 0.2, h: 0.1 }] };
  near(B.boxAt(moving, 1), { x: 0.1, y: 0.2 });
  near(B.boxAt(moving, 4), { x: 0.3, y: 0.4 }); // halfway, and the ease is symmetric
  near(B.boxAt(moving, 9), { x: 0.5, y: 0.6 });
  assert.ok(B.boxAt(moving, 2.5).x < 0.1 + 0.4 * 0.125); // eased: slower than straight at the start
});

test('fading in and out, and see-through', () => {
  const b = { start: 2, end: 8, x: 0, y: 0, w: 0.1, h: 0.1, fade: 1, opacity: 0.5 };
  assert.equal(B.alphaAt(b, 1), 0);
  assert.equal(B.alphaAt(b, 2), 0);
  assert.equal(B.alphaAt(b, 2.5), 0.25);
  assert.equal(B.alphaAt(b, 5), 0.5);
  assert.equal(B.alphaAt(b, 7.5), 0.25);
  assert.equal(B.alphaAt({ start: 0, end: 4, x: 0, y: 0, w: 0.1, h: 0.1 }, 2), 1); // defaults: no fade, fully hiding
  assert.equal(B.alphaAt({ start: 0, end: 1, fade: 5 }, 0.5), 1); // a fade never longer than half the blur
  assert.deepEqual(B.frames([b, { ...b, start: 20, end: 30 }], 5).map((f) => f.index), [0]);
});

test('placing, keying and unkeying', () => {
  const b = { start: 0, end: 10, x: 0.1, y: 0.1, w: 0.2, h: 0.2 };
  near(B.placeAt(b, 3, { x: 0.5, y: 0.5, w: 0.2, h: 0.2 }), { x: 0.5, y: 0.5 }); // still: just moves
  const keyed = B.addKey(b, 4);
  assert.deepEqual(keyed.keys.map((k) => k.t), [0, 4]);
  const moved = B.placeAt(keyed, 4.02, { x: 0.6, y: 0.1, w: 0.2, h: 0.2 }); // same key, updated
  assert.deepEqual(moved.keys.map((k) => k.t), [0, 4.02]);
  near(B.boxAt(moved, 10), { x: 0.6 });
  const back = B.removeKey(B.removeKey(moved, 4), 0);
  assert.equal(back.keys, undefined);
  near(back, { x: 0.1, y: 0.1 });
  assert.equal(B.removeKey(moved, 7), moved); // nothing near
});

test('corner handles resize from the opposite corner; the inside moves; the bar retimes', () => {
  const box = { x: 0.2, y: 0.2, w: 0.4, h: 0.2 };
  assert.equal(B.handleAt(box, { x: 0.61, y: 0.41 }), 'se');
  assert.equal(B.handleAt(box, { x: 0.4, y: 0.3 }), 'move');
  assert.equal(B.handleAt(box, { x: 0.9, y: 0.9 }), null);
  near(B.dragBox(box, 'se', 0.1, 0.1), { x: 0.2, y: 0.2, w: 0.5, h: 0.3 });
  near(B.dragBox(box, 'nw', 0.1, 0.05), { x: 0.3, y: 0.25, w: 0.3, h: 0.15 });
  near(B.dragBox(box, 'move', 0.9, 0), { x: 0.6, y: 0.2, w: 0.4, h: 0.2 }); // stays in the picture
  const clip = { start: 1, end: 9 };
  assert.equal(B.retime({ start: 2, end: 5 }, 'start', 0, clip).start, 1);
  assert.equal(B.retime({ start: 2, end: 5 }, 'start', 4.95, clip).start, 4.8);
  assert.equal(B.retime({ start: 2, end: 5 }, 'end', 12, clip).end, 9);
});
