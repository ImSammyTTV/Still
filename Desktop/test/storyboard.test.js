const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../web/shared/storyboard.js');

// The same cases are in the Mac app's VideoStoryboardTests.
test('frames spread through what is kept, labelled with the finished video’s time', () => {
  const f = S.frames({ start: 0, end: 40 }, [{ start: 10, end: 20 }], [], { count: 3 });
  assert.deepEqual(f.map((x) => x.time), [5, 25, 35]);
  assert.deepEqual(f.map((x) => x.label), ['0:05', '0:15', '0:25']);
});

test('with chapters, one frame each at its start, named', () => {
  const f = S.frames({ start: 0, end: 100 }, [], [{ time: 70, title: 'Share' }, { time: 0, title: 'Intro' }]);
  assert.deepEqual(f, [{ time: 0.05, label: '0:00  Intro' }, { time: 70.05, label: '1:10  Share' }]);
});

test('a short video shows tenths, so times don’t repeat', () => {
  assert.deepEqual(S.frames({ start: 0, end: 4 }, [], [], { count: 4 }).map((x) => x.label), ['0:00.5', '0:01.5', '0:02.5', '0:03.5']);
});

test('the sheet grows by rows of up to four', () => {
  assert.deepEqual(S.layout(6, 1920, 1080), { cols: 4, rows: 2, tileWidth: 480, tileHeight: 270, strip: 34, gap: 16, width: 2000, height: 656 });
  assert.equal(S.layout(2, 1080, 1920).cols, 2);
});
