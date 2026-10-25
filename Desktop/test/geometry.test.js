const test = require('node:test');
const assert = require('node:assert/strict');
const G = require('../web/shared/geometry');

test('drag selection works in every direction and clamps to the display', () => {
  const bounds = { x: 0, y: 0, w: 100, h: 100 };
  assert.deepEqual(G.dragRect({ x: 50, y: 50 }, { x: 20, y: 10 }, { bounds }), { x: 20, y: 10, w: 30, h: 40 });
  assert.deepEqual(G.dragRect({ x: 90, y: 90 }, { x: 140, y: 120 }, { bounds }), { x: 90, y: 90, w: 10, h: 10 });
});

test('Shift makes a square and a locked aspect ratio sets the height', () => {
  assert.deepEqual(G.dragRect({ x: 0, y: 0 }, { x: 40, y: 10 }, { square: true }), { x: 0, y: 0, w: 40, h: 40 });
  assert.deepEqual(G.dragRect({ x: 0, y: 0 }, { x: 160, y: 10 }, { aspect: 16 / 9 }), { x: 0, y: 0, w: 160, h: 90 });
});

test('arrow keys move or resize inside the display', () => {
  const bounds = { x: 0, y: 0, w: 100, h: 100 };
  assert.deepEqual(G.nudge({ x: 95, y: 0, w: 10, h: 10 }, 10, -5, { bounds }), { x: 90, y: 0, w: 10, h: 10 });
  assert.deepEqual(G.nudge({ x: 0, y: 0, w: 10, h: 10 }, 5, 5, { resize: true, bounds }), { x: 0, y: 0, w: 15, h: 15 });
});

test('Space window mode picks the frontmost window under the pointer', () => {
  const windows = [{ id: 1, x: 10, y: 10, w: 50, h: 50 }, { id: 2, x: 0, y: 0, w: 200, h: 200 }];
  assert.equal(G.windowAt(windows, { x: 20, y: 20 }).id, 1);
  assert.equal(G.windowAt(windows, { x: 100, y: 100 }).id, 2);
  assert.equal(G.windowAt(windows, { x: 300, y: 300 }), null);
});

test('display points map to image pixels on high-DPI screens', () => {
  assert.deepEqual(G.toPixels({ x: 10.2, y: 20, w: 30, h: 0.1 }, 2), { x: 20, y: 40, w: 60, h: 1 });
});

test('backgrounds add padding and honour an aspect ratio', () => {
  assert.deepEqual(G.canvasSize({ w: 100, h: 50 }, { padding: 10 }), { w: 120, h: 70 });
  assert.deepEqual(G.canvasSize({ w: 100, h: 100 }, { aspect: 2 }), { w: 200, h: 100 });
});

test('names, durations and shortcut labels', () => {
  assert.equal(G.captureName(new Date(2026, 9, 25, 15, 4, 9)), 'Still 2026-10-25 at 15.04.09');
  assert.equal(G.formatDuration(125.9), '2:05');
  assert.equal(G.shortcutLabel('CommandOrControl+Shift+4', 'win32'), 'Ctrl + Shift + 4');
  assert.equal(G.shortcutLabel('Super+Alt+S', 'linux'), 'Super + Alt + S');
});
