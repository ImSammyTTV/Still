const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../web/shared/callouts.js');

// The same cases are in the Mac app's VideoCalloutTests.
test('new callouts are three seconds long, arrows and boxes in the middle', () => {
  assert.deepEqual(C.add([], 'arrow', 1, { start: 0, end: 10 }), [{ kind: 'arrow', start: 1, end: 4, color: '#FF453A', x: 0.5, y: 0.5, x2: 0.38, y2: 0.36 }]);
  assert.deepEqual(C.add([], 'box', 9, { start: 0, end: 10 })[0], { kind: 'box', start: 9, end: 10, color: '#FF453A', x: 0.35, y: 0.35, w: 0.3, h: 0.3 });
});

test('callouts fade in and out over 0.2 s', () => {
  const c = [{ kind: 'box', start: 1, end: 3 }];
  assert.equal(C.at(c, 0.5).length, 0);
  assert.ok(Math.abs(C.at(c, 1.1)[0].alpha - 0.5) < 1e-9);
  assert.equal(C.at(c, 2)[0].alpha, 1);
});

test('an arrow points at each click, one per burst, with room for its tail', () => {
  const arrows = C.fromClicks([[2, 0.6, 0.5], [2.5, 0.6, 0.5], [5, 0.1, 0.1], [30, 0.5, 0.5]], { start: 0, end: 10 });
  assert.equal(arrows.length, 2);
  assert.deepEqual(arrows[0], { kind: 'arrow', start: 1.6, end: 3.2, color: '#FF453A', x: 0.6, y: 0.5, x2: 0.48, y2: 0.38 });
  assert.ok(Math.abs(arrows[1].x2 - 0.22) < 1e-9 && Math.abs(arrows[1].y2 - 0.22) < 1e-9, 'tail goes the other way near the corner');
});

test('the arrow head sits either side of the tip', () => {
  const [a, b] = C.head({ x: 0, y: 0 }, { x: 10, y: 0 }, 4);
  assert.ok(a.x < 10 && b.x < 10 && Math.abs(a.y + b.y) < 1e-9);
});

// The same cases are in the Mac app's VideoCalloutTests (testCalloutKeyframesFadeAndStrength).
test('a keyed callout glides between keyframes, fades over its own time and can be see-through', () => {
  const arrow = { kind: 'arrow', start: 0, end: 4, color: '#FF453A', x: 0.5, y: 0.5, x2: 0.4, y2: 0.4 };
  const keyed = C.placeAt(C.addKey(arrow, 2), 2, { x: 0.9, y: 0.1 });
  assert.deepEqual(keyed.keys, [{ t: 0, x: 0.5, y: 0.5, x2: 0.4, y2: 0.4 }, { t: 2, x: 0.9, y: 0.1, x2: 0.4, y2: 0.4 }]);
  const mid = C.shapeAt(keyed, 1);
  assert.ok(Math.abs(mid.x - 0.7) < 1e-9 && Math.abs(mid.y - 0.3) < 1e-9, 'halfway, eased');
  assert.deepEqual(C.shapeAt(keyed, 3), { x: 0.9, y: 0.1, x2: 0.4, y2: 0.4 }, 'stays at the last key');
  assert.equal(C.at([keyed], 3)[0].callout.x, 0.9);
  assert.equal(C.hasKey(keyed, 2.1), true);
  assert.deepEqual(C.removeKey(C.removeKey(keyed, 2), 0), { ...arrow, x: 0.5, y: 0.5 });
  // Unset fade keeps the quick 0.2 s ramp; a set fade eases over that time; strength scales it.
  assert.equal(C.alphaAt(arrow, 0.1), 0.5);
  const soft = { ...arrow, fade: 1, opacity: 0.5 };
  assert.equal(C.alphaAt(soft, 0.5), 0.25);
  assert.equal(C.alphaAt(soft, 2), 0.5);
  assert.equal(C.alphaAt(soft, 5), 0);
  // An unkeyed box just moves.
  const box = { kind: 'box', start: 0, end: 3, color: '#fff', x: 0.1, y: 0.1, w: 0.2, h: 0.2 };
  assert.deepEqual(C.placeAt(box, 1, { x: 0.3 }), { ...box, x: 0.3 });
});
