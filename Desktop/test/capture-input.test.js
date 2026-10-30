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
