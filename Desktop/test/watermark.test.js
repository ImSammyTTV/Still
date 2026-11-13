const test = require('node:test');
const assert = require('node:assert/strict');
const W = require('../web/shared/watermark.js');

// The same cases are in the Mac app's WatermarkTests.
test('no text means no watermark, and odd settings fall back', () => {
  assert.equal(W.normalize({ text: '   ' }), null);
  assert.equal(W.normalize(null), null);
  assert.deepEqual(W.normalize({ text: ' © Sam ', position: 'middle', size: 'huge', opacity: 5 }), { kind: 'text', image: '', text: '© Sam', position: 'bottomRight', size: 'medium', opacity: 1 });
});

test('sized from the shorter side and kept off the edges', () => {
  assert.deepEqual(W.placement(1920, 1080, W.normalize({ text: 'x' })), { fontSize: 35, margin: 32, x: 1888, y: 1048, alignX: 1, alignY: 1 });
  assert.deepEqual(W.placement(400, 300, W.normalize({ text: 'x', position: 'topLeft', size: 'small' })), { fontSize: 11, margin: 10, x: 10, y: 10, alignX: 0, alignY: 0 });
  assert.deepEqual(W.placement(1000, 800, W.normalize({ text: 'x', position: 'center', size: 'large' })), { fontSize: 38, margin: 34, x: 500, y: 400, alignX: 0.5, alignY: 0.5 });
  assert.equal(W.placement(8000, 6000, W.normalize({ text: 'x', size: 'large' })).fontSize, 96);
});

test('an image watermark needs a picture, and fits a square from the shorter side in its corner', () => {
  const W = require('../web/shared/watermark.js');
  assert.equal(W.normalize({ kind: 'image', image: '' }), null);
  assert.equal(W.normalize({ kind: 'image', image: '/x/logo.png' }).kind, 'image');
  assert.equal(W.normalize({ kind: 'text', text: 'Hi', image: '/x/logo.png' }).kind, 'text');
  const wm = W.normalize({ kind: 'image', image: 'logo.png', position: 'bottomRight', size: 'medium' });
  // 1000 × 600 picture: square of 0.18 × 600 = 108; a 400 × 200 logo fits as 108 × 54; margin 18.
  assert.deepStrictEqual(W.imageFrame(1000, 600, 400, 200, wm), { x: 1000 - 18 - 108, y: 600 - 18 - 54, w: 108, h: 54 });
  assert.deepStrictEqual(W.imageFrame(1000, 600, 100, 300, { ...wm, position: 'topLeft' }), { x: 18, y: 18, w: 36, h: 108 });
  assert.deepStrictEqual(W.imageFrame(1000, 600, 200, 200, { ...wm, position: 'center' }), { x: 446, y: 246, w: 108, h: 108 });
});
