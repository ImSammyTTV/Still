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
