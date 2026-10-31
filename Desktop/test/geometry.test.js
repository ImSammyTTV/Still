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

test('recording qualities match the Mac and stay within bounds', () => {
  assert.equal(G.videoBitrate(1920, 1080, 30, 'high'), 11_197_440);
  assert.equal(G.videoBitrate(1920, 1080, 30, 'balanced'), 5_598_720);
  assert.equal(G.videoBitrate(1920, 1080, 30, 'compact'), 2_799_360);
  assert.equal(G.videoBitrate(1920, 1080, 30, undefined), 11_197_440); // Settings from before qualities existed.
  assert.equal(G.videoBitrate(10, 10, 1, 'high'), 400_000);
  assert.equal(G.videoBitrate(7680, 4320, 60, 'high'), 100_000_000);
  assert.equal(G.videoBitrate(1920, 1080, 30, 'bitrate:8000000'), 8_000_000); // Chosen in Settings.
  assert.equal(G.videoBitrate(1920, 1080, 30, 'bitrate:500'), 1_000_000);
  assert.equal(G.videoBitrate(1920, 1080, 30, 'bitrate:x'), 11_197_440);
});

test('picked colours are hex, newest first, without repeats, and get readable ink', () => {
  assert.equal(G.hexColor(255, 128.4, 0), '#FF8000');
  assert.equal(G.hexColor(-4, 300, 15), '#00FF0F');
  assert.deepEqual(G.rememberColor(['#111111', '#ff8000', '#222222'], '#FF8000', 3), ['#FF8000', '#111111', '#222222']);
  assert.deepEqual(G.rememberColor(undefined, '#ABCDEF'), ['#ABCDEF']);
  assert.equal(G.rememberColor(Array.from({ length: 12 }, (_, i) => `#00000${i % 10}`), '#FFFFFF').length, 10);
  assert.equal(G.inkOn('#FFFFFF'), '#000000'); assert.equal(G.inkOn('#1D1D1F'), '#FFFFFF');
});

test('file names follow the pattern, the same way the app names files', () => {
  const date = new Date(2026, 9, 31, 9, 5, 7);
  assert.equal(G.fileName(G.DEFAULT_NAME, { date, width: 800, height: 600 }), 'Screenshot 2026-10-31 at 09.05.07');
  assert.equal(G.fileName('{type} #{n} {width}x{height}', { date, kind: 'recording', n: 12 }), 'Recording #12 x');
  assert.equal(G.fileName('Bug: {date}/{time}?', { date }), 'Bug- 2026-10-31-09.05.07-');
  assert.equal(G.fileName(' ... ', { date }), 'Screenshot 2026-10-31 at 09.05.07');
  assert.equal([...G.fileName('x'.repeat(300), { date })].length, 180);
});

// The same cases are in the Mac app's VideoExportSizeTests.
test('export sizes bring the shorter side down, never up, and stay even', () => {
  assert.deepEqual(G.exportSize(2880, 1800, 1080), { width: 1728, height: 1080 });
  assert.deepEqual(G.exportSize(1920, 1080, 720), { width: 1280, height: 720 });
  assert.deepEqual(G.exportSize(1080, 1920, 720), { width: 720, height: 1280 });
  assert.deepEqual(G.exportSize(1280, 720, 1080), { width: 1280, height: 720 }, 'no enlarging');
  assert.deepEqual(G.exportSize(1001, 563, 0), { width: 1000, height: 562 }, 'original, made even');
  assert.equal(G.sizeLabel(G.estimateBytes(8_000_000, 60)), '61 MB');
});
