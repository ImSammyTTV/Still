const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../web/shared/marks');

const arrow = (extra = {}) => ({ type: 'arrow', x1: 0, y1: 0, x2: 100, y2: 0, stroke: 4, ...extra });
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} is not ${b}`);

test('marks saved before styles existed keep the look they were saved with', () => {
  assert.equal(M.arrowStyle(arrow()), 'filled');
  assert.equal(M.textStyle({ type: 'text' }), 'shadow');
  assert.equal(M.arrowStyle(arrow({ style: 'something-new' })), 'filled');
  assert.equal(M.textWeight({ type: 'text' }), 600);
  // The geometry the editor drew before styles: a closed head, with the shaft stopping inside it.
  const shape = M.arrowShape(arrow());
  assert.equal(shape.heads.length, 1);
  assert.equal(shape.heads[0].closed, true);
  close(shape.end.x, 100 - 16.8 * 0.75);
  close(shape.heads[0].left.x, 100 - 16.8 * Math.cos(-0.45));
  close(shape.heads[0].right.y, -16.8 * Math.sin(0.45));
});

test('arrow styles match the Mac app', () => {
  const plain = M.arrowShape(arrow({ style: 'plain' }));
  assert.equal(plain.heads[0].closed, false);
  assert.deepEqual(plain.end, { x: 100, y: 0 });
  const double = M.arrowShape(arrow({ style: 'double' }));
  assert.equal(double.heads.length, 2);
  assert.ok(double.heads[0].left.x < 100, 'the end head points forwards');
  assert.ok(double.heads[1].left.x > 0, 'the start head points backwards');
  const curved = M.arrowShape(arrow({ style: 'curved' }));
  assert.deepEqual(curved.control, { x: 50, y: -30 });
  assert.equal(curved.heads[0].closed, false);
});

test('a curved arrow bends where it was dragged, is hit along the curve and moves its bend', () => {
  const m = arrow({ style: 'curved', cx: 50, cy: 100 });
  assert.deepEqual(M.curveControl(m), { x: 50, y: 100 });
  assert.ok(M.distanceToPath({ x: 50, y: 50 }, m) < 1, 'the middle of the curve');
  assert.ok(M.distanceToPath({ x: 50, y: 0 }, m) > 40, 'the straight line between the ends');
  const b = M.pathBounds(m);
  close(b.y, 0); assert.ok(Math.abs(b.h - 50) < 1, 'as tall as the curve, not its control point');
  assert.equal(M.isCurved({ type: 'line', style: 'curved' }), false);
});

test('straight lines keep their plain hit test and bounds', () => {
  const m = { type: 'line', x1: 10, y1: 10, x2: 0, y2: 10 };
  assert.deepEqual(M.pathBounds(m), { x: 0, y: 10, w: 10, h: 0 });
  assert.equal(M.distanceToPath({ x: 5, y: 13 }, m), 3);
});

test('text styles: boxes, tails and ink', () => {
  const text = (style, color = '#FF453A') => ({ type: 'text', x: 100, y: 200, size: 25, text: 'One\nTwo', color, style });
  assert.equal(M.textLayout(text('shadow'), 80).box, null);
  assert.deepEqual(M.textLayout(text('shadow'), 80).bounds, { x: 100, y: 200, w: 80, h: 60 });
  const label = M.textLayout(text('label'), 80);
  assert.deepEqual(label.bounds, { x: 92, y: 195, w: 96, h: 70 });
  assert.equal(label.tail, null);
  const bubble = M.textLayout(text('bubble'), 80);
  assert.equal(bubble.tail.length, 3);
  assert.equal(bubble.bounds.h, 70 + 12, 'bounds include the tail so it can be clicked');
  assert.ok(M.textLayout(text('outline'), 80).bounds.w > 80, 'bounds include the outline');
  assert.equal(M.textWeight(text('plain')), 400);
  assert.equal(M.textFont(text('bold'), 'Segoe UI'), '600 25px Segoe UI');
  assert.equal(M.textInk(text('border')), '#FF453A');
  assert.equal(M.textInk(text('label')), '#FFFFFF');
  assert.equal(M.textInk(text('label', '#FFFFFF')), '#1D1D1F', 'white labels stay readable');
  assert.equal(M.textInk(text('bubble', '#FFD60A')), '#1D1D1F');
});

test('rotating and flipping map every corner to the right place', () => {
  const apply = ([a, b, c, d, e, f], x, y) => [a * x + c * y + e, b * x + d * y + f];
  const size = { w: 40, h: 10 };
  const cw = M.orient(size, 'cw');
  assert.deepEqual([cw.w, cw.h], [10, 40]);
  assert.deepEqual(apply(cw.matrix, 0, 0), [10, 0], 'top left goes to top right');
  assert.deepEqual(apply(cw.matrix, 40, 10), [0, 40], 'bottom right goes to bottom left');
  const ccw = M.orient(size, 'ccw');
  assert.deepEqual([ccw.w, ccw.h], [10, 40]);
  assert.deepEqual(apply(ccw.matrix, 0, 0), [0, 40], 'top left goes to bottom left');
  assert.deepEqual(apply(ccw.matrix, 40, 10), [10, 0], 'bottom right goes to top right');
  assert.deepEqual(apply(M.orient(size, 'flip-h').matrix, 0, 0), [40, 0]);
  assert.deepEqual(apply(M.orient(size, 'flip-v').matrix, 0, 0), [0, 10]);
  assert.throws(() => M.orient(size, 'sideways'));
});

test('resize keeps the ratio when locked and refuses sizes the Mac app refuses', () => {
  assert.equal(M.linkedSide(800, 1600, 900), 450);
  assert.equal(M.linkedSide('800', 1600, 900), 450);
  assert.equal(M.linkedSide(1, 1600, 9), 1, 'never collapses to nothing');
  assert.equal(M.resizeProblem(1600, 900), null);
  assert.ok(M.resizeProblem(0, 900));
  assert.ok(M.resizeProblem(10.5, 900));
  assert.ok(M.resizeProblem(30001, 10));
  assert.ok(M.resizeProblem(20000, 20000));
});

test('dropped images are placed at most 65% of the canvas and stay inside it', () => {
  const canvas = { x: 0, y: 0, w: 1000, h: 500 };
  assert.deepEqual(M.placeImage({ w: 100, h: 100 }, canvas), { x: 450, y: 200, w: 100, h: 100 }, 'small images keep their size, centred');
  assert.deepEqual(M.placeImage({ w: 2000, h: 500 }, canvas), { x: 175, y: 169, w: 650, h: 163 });
  assert.deepEqual(M.placeImage({ w: 100, h: 100 }, canvas, { x: 300, y: 300 }), { x: 250, y: 250, w: 100, h: 100 });
  assert.deepEqual(M.placeImage({ w: 100, h: 100 }, canvas, { x: -5000, y: 9000 }), { x: 0, y: 400, w: 100, h: 100 }, 'a drop off the canvas lands at its edge');
  assert.deepEqual(M.placeImage({ w: 100, h: 100 }, { x: 50, y: 60, w: 400, h: 300 }), { x: 200, y: 160, w: 100, h: 100 }, 'centres in a crop');
});

test('only image files are taken from a drop, and never Still\'s own temporary files', () => {
  assert.deepEqual(M.droppedImages(['C:\\Pics\\A.PNG', '/home/me/b.jpeg', '/home/me/notes.txt', '/home/me/c.webp']), ['C:\\Pics\\A.PNG', '/home/me/b.jpeg', '/home/me/c.webp']);
  assert.deepEqual(M.droppedImages(['C:\\Users\\me\\AppData\\Local\\app.still.desktop\\still-tmp\\Still 2026.png', '/home/me/.cache/app.still.desktop/still-tmp/x.png']), []);
  assert.deepEqual(M.droppedImages(undefined), []);
});

test('drop positions become page coordinates on each platform', () => {
  assert.deepEqual(M.dropPoint({ x: 300, y: 150 }, 1.5, 'win32'), { clientX: 200, clientY: 100 });
  assert.deepEqual(M.dropPoint({ x: 300, y: 150 }, 2, 'linux'), { clientX: 300, clientY: 150 });
  assert.deepEqual(M.dropPoint({ x: 300, y: 150 }, 2, 'darwin'), { clientX: 300, clientY: 150 });
});

test('the same image is only stored once', () => {
  const assets = {};
  assert.equal(M.addAsset(assets, 'data:one'), 'a1');
  assert.equal(M.addAsset(assets, 'data:two'), 'a2');
  assert.equal(M.addAsset(assets, 'data:one'), 'a1');
  delete assets.a1;
  assert.equal(M.addAsset(assets, 'data:three'), 'a1');
});

test('undo states are matched to the images they mention', () => {
  const assets = { a1: 'x', a2: 'y', a3: 'z' };
  const states = [JSON.stringify({ source: 'a1', marks: [] }), JSON.stringify({ marks: [{ type: 'image', asset: 'a3' }] })];
  assert.deepEqual(M.unusedAssets(assets, states), ['a2']);
  assert.deepEqual(M.unusedAssets({ a1: 'x', a11: 'y' }, [JSON.stringify({ source: 'a11' })]), ['a1'], 'a1 is not mistaken for a11');
});

test('projects save only the images they use, and reopen with them', () => {
  const doc = { marks: [{ type: 'image', asset: 'a2', x: 1, y: 2, w: 3, h: 4 }, { type: 'arrow' }], crop: null, source: 'a3', bg: { style: 'none', padding: 10 } };
  const saved = JSON.parse(JSON.stringify(M.projectFile(doc, { a1: 'deleted', a2: 'placed', a3: 'rotated' })));
  assert.equal(saved.version, 2);
  assert.deepEqual(saved.assets, { a2: 'placed', a3: 'rotated' });
  const defaults = { marks: [], crop: null, source: null, bg: { style: 'none', padding: 64, shadow: true } };
  const opened = M.openProject(saved, defaults);
  assert.deepEqual(opened.assets, saved.assets);
  assert.equal(opened.doc.assets, undefined, 'image data stays out of undo states');
  assert.equal(opened.doc.version, undefined);
  assert.equal(opened.doc.source, 'a3');
  assert.deepEqual(opened.doc.marks, doc.marks);
  assert.deepEqual(opened.doc.bg, { style: 'none', padding: 10, shadow: true });
});

test('a project from an older version still opens', () => {
  const old = { version: 1, marks: [{ type: 'arrow', x1: 0, y1: 0, x2: 9, y2: 9, color: '#FF453A', stroke: 4 }], crop: { x: 1, y: 2, w: 3, h: 4 }, bg: { style: 'midnight' } };
  const defaults = { marks: [], crop: null, source: null, bg: { style: 'none', padding: 64 } };
  const { doc, assets } = M.openProject(old, defaults);
  assert.deepEqual(assets, {});
  assert.equal(doc.source, null);
  assert.deepEqual(doc.crop, old.crop);
  assert.equal(doc.marks.length, 1);
  assert.deepEqual(doc.bg, { style: 'midnight', padding: 64 });
  assert.deepEqual(M.openProject(null, defaults).doc, defaults);
});
