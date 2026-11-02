const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../web/shared/sizes.js');

const near = (a, b) => Object.keys(b).forEach((k) => assert.ok(Math.abs(a[k] - b[k]) < 1e-6, `${k}: ${a[k]} vs ${b[k]}`));
const bounds = { x: 0, y: 0, w: 2000, h: 1000 };

// The same cases are in the Mac app's SocialSizesTests.
test('every size has a unique id and whole pixel sides', () => {
  assert.equal(new Set(S.SIZES.map((s) => s.id)).size, S.SIZES.length);
  for (const s of S.SIZES) assert.ok(Number.isInteger(s.w) && Number.isInteger(s.h) && s.w > 0 && s.h > 0, s.id);
  assert.equal(S.byId('yt-banner').safe.w, 1546);
  assert.equal(S.byId('nope'), null);
});

test('a size starts as the largest crop of its shape in the middle', () => {
  near(S.centered(bounds, 16 / 9), { x: (2000 - 1000 * 16 / 9) / 2, y: 0, w: 1000 * 16 / 9, h: 1000 });
  near(S.centered(bounds, 3), { x: 0, y: (1000 - 2000 / 3) / 2, w: 2000, h: 2000 / 3 });
  near(S.centered(bounds, 1), { x: 500, y: 0, w: 1000, h: 1000 });
});

test('dragging keeps the shape, follows the pointer along its diagonal and stays in the picture', () => {
  near(S.dragged({ x: 100, y: 100 }, { x: 500, y: 300 }, 2, bounds), { x: 100, y: 100, w: 400, h: 200 });
  near(S.dragged({ x: 100, y: 100 }, { x: 500, y: 150 }, 2, bounds), { x: 100, y: 100, w: 340, h: 170 });
  near(S.dragged({ x: 100, y: 100 }, { x: 150, y: 400 }, 2, bounds), { x: 100, y: 100, w: 160, h: 80 });
  near(S.dragged({ x: 500, y: 500 }, { x: 300, y: 400 }, 2, bounds), { x: 300, y: 400, w: 200, h: 100 });
  // Out of room at the bottom: as big as fits.
  near(S.dragged({ x: 100, y: 900 }, { x: 900, y: 990 }, 2, bounds), { x: 100, y: 900, w: 200, h: 100 });
});

test('a corner drag keeps the opposite corner where it was, and pulling in on one side shrinks it', () => {
  const r = { x: 200, y: 200, w: 400, h: 200 };
  near(S.cornered(r, 'se', { x: 800, y: 250 }, 2, bounds), { x: 200, y: 200, w: 500, h: 250 });
  near(S.cornered(r, 'se', { x: 480, y: 400 }, 2, bounds), { x: 200, y: 200, w: 304, h: 152 });
  near(S.cornered(r, 'nw', { x: 200, y: 200 }, 2, bounds), r);
  near(S.cornered(r, 'nw', { x: 400, y: 350 }, 2, bounds), { x: 420, y: 310, w: 180, h: 90 });
});

test('the safe area sits in the middle at the same proportion, and the note warns about enlarging', () => {
  const banner = S.byId('yt-banner');
  near(S.safeArea({ x: 0, y: 0, w: 1280, h: 720 }, banner), { x: (1280 - 773) / 2, y: (720 - 211.5) / 2, w: 773, h: 211.5 });
  assert.equal(S.safeArea({ x: 0, y: 0, w: 10, h: 10 }, S.byId('ig-square')), null);
  assert.equal(S.note({ x: 0, y: 0, w: 1280, h: 720 }, banner), '2560 × 1440 · enlarged, may look soft');
  assert.equal(S.note({ x: 0, y: 0, w: 2560, h: 1440 }, banner), '2560 × 1440');
  assert.equal(S.note(null, banner), '');
});
