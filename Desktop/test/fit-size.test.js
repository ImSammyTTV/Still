const test = require('node:test');
const assert = require('node:assert');
const F = require('../web/shared/fit-size.js');

// A stand-in encoder: bytes go with pixels and quality, like a JPEG of a screen roughly does.
const fake = (w, h, perPixel = 1) => async (scale, quality) => Math.round(w * scale * h * scale * perPixel * (0.2 + quality));

test('plans a centred square and keeps the shape when only the width is given', () => {
  assert.deepStrictEqual(F.plan({ w: 1920, h: 1080 }, { square: true, width: 500 }), { crop: { x: 420, y: 0, w: 1080, h: 1080 }, w: 500, h: 500 });
  assert.deepStrictEqual(F.plan({ w: 1000, h: 500 }, { width: 400 }), { crop: { x: 0, y: 0, w: 1000, h: 500 }, w: 400, h: 200 });
  assert.deepStrictEqual(F.plan({ w: 800, h: 1200 }, { square: true }), { crop: { x: 0, y: 200, w: 800, h: 800 }, w: 800, h: 800 });
});

test('no limit: full size at the top quality', async () => {
  const r = await F.fit(fake(100, 100), {});
  assert.deepStrictEqual([r.scale, r.quality, r.fits], [1, 0.92, true]);
});

test('JPEG lowers quality first, keeping the size', async () => {
  const r = await F.fit(fake(1000, 1000), { limit: 1_000_000, jpeg: true });
  assert.strictEqual(r.scale, 1);
  assert.ok(r.fits && r.bytes <= 1_000_000 && r.quality < 0.92 && r.quality >= 0.5);
  assert.ok(r.bytes > 900_000, `uses most of the room: ${r.bytes}`);
});

test('JPEG shrinks the picture when even low quality is too big', async () => {
  const r = await F.fit(fake(1000, 1000), { limit: 300_000, jpeg: true });
  assert.ok(r.fits && r.bytes <= 300_000 && r.scale < 1, JSON.stringify(r));
});

test('PNG only shrinks', async () => {
  const r = await F.fit(fake(1000, 1000), { limit: 400_000, jpeg: false });
  assert.ok(r.fits && r.bytes <= 400_000 && r.scale < 1 && r.quality === 1, JSON.stringify(r));
});

test('an impossible limit gives back the smallest it made, marked as not fitting', async () => {
  const r = await F.fit(async () => 5000, { limit: 10, jpeg: true });
  assert.strictEqual(r.fits, false);
});

test('sizes read as people say them', () => {
  assert.strictEqual(F.kb(480 * 1024), '480 KB');
  assert.strictEqual(F.kb(2.5 * 1024 * 1024), '2.5 MB');
});
