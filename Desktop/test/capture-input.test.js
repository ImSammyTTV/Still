const test = require('node:test');
const assert = require('node:assert/strict');
const input = require('../web/shared/capture-input');
test('Escape cancels capture from dimension inputs as well as toolbar buttons', () => {
  for (const editingText of [true, false]) assert.equal(input.keyAction({ key: 'Escape', editingText, purpose: 'record' }), 'cancel');
});
test('Space selects windows in both screenshot and recording modes', () => {
  for (const purpose of ['screenshot', 'record']) assert.equal(input.keyAction({ code: 'Space', purpose }), 'window');
  assert.equal(input.keyAction({ code: 'Space', purpose: 'text' }), 'pass');
});
test('Typing dimensions and system key chords retain Space', () => {
  assert.equal(input.keyAction({ code: 'Space', purpose: 'record', editingText: true }), 'pass');
  assert.equal(input.keyAction({ code: 'Space', purpose: 'record', commandModifier: true }), 'pass');
});
test('Window sources are not cropped again using monitor coordinates', () => {
  assert.equal(input.shouldCrop('window', false), false);
  assert.equal(input.shouldCrop('browser', false), false);
  assert.equal(input.shouldCrop('monitor', false), true);
  assert.equal(input.shouldCrop('monitor', true), false);
});
test('A window recording cannot silently record the whole screen', () => {
  assert.equal(input.recordingSourceAllowed(true, 'window'), true);
  assert.equal(input.recordingSourceAllowed(true, 'monitor'), false);
  assert.equal(input.recordingSourceAllowed(true, undefined), false);
  assert.equal(input.recordingSourceAllowed(false, 'monitor'), true);
});
test('Linux draws every frame when the controls have to be blacked out, but never for a window', () => {
  const mask = { x: 810, y: 990, w: 300, h: 52 };
  assert.equal(input.shouldDraw('monitor', true, mask), true);
  assert.equal(input.shouldDraw(undefined, true, mask), true);
  assert.equal(input.shouldDraw('monitor', true, undefined), false);
  assert.equal(input.shouldDraw('monitor', false, undefined), true);
  assert.equal(input.shouldDraw('window', true, mask), false);
  assert.equal(input.shouldDraw('window', false, mask), false);
});
test('The controls are blacked out where they sit in the cropped picture', () => {
  const mask = { x: 810, y: 990, w: 300, h: 52 };
  // The whole 1920x1080 display, recorded at its own size and at half size.
  assert.deepEqual(input.maskRect(mask, { x: 0, y: 0, w: 1920, h: 1080 }, 1920, 1080), { x: 810, y: 990, w: 300, h: 52 });
  assert.deepEqual(input.maskRect(mask, { x: 0, y: 0, w: 1920, h: 1080 }, 960, 540), { x: 405, y: 495, w: 150, h: 26 });
  // Only part of them inside the selection, and rounded outwards.
  assert.deepEqual(input.maskRect(mask, { x: 1000, y: 0, w: 920, h: 1001 }, 920, 1001), { x: 0, y: 990, w: 110, h: 11 });
  assert.deepEqual(input.maskRect({ x: 10.5, y: 10.5, w: 10, h: 10 }, { x: 0, y: 0, w: 100, h: 100 }, 100, 100), { x: 10, y: 10, w: 11, h: 11 });
  // Outside the selection, or nothing to hide.
  assert.equal(input.maskRect(mask, { x: 0, y: 0, w: 800, h: 600 }, 800, 600), null);
  assert.equal(input.maskRect(undefined, { x: 0, y: 0, w: 800, h: 600 }, 800, 600), null);
});
