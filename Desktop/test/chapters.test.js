const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../web/shared/chapters.js');

// The same cases are in the Mac app's VideoChaptersTests.
test('chapters list in the finished video’s time, starting at 0:00', () => {
  const chapters = [{ time: 75, title: 'Setting up' }, { time: 10, title: 'Welcome' }, { time: 200, title: '  Sharing   it ' }];
  assert.equal(C.list(chapters, { start: 0, end: 300 }, []), '0:00 Intro\n0:10 Welcome\n1:15 Setting up\n3:20 Sharing it');
  // Trimmed to start at 10 s, 20 s cut out before Setting up, at 2× speed.
  assert.equal(C.list(chapters, { start: 10, end: 300 }, [{ start: 30, end: 50 }], 2), '0:00 Welcome\n0:22 Setting up\n1:25 Sharing it');
});

test('chapters in a cut or outside the clip are left out, and long videos show hours', () => {
  assert.equal(C.list([{ time: 40, title: 'Gone' }], { start: 0, end: 100 }, [{ start: 30, end: 50 }]), '');
  assert.equal(C.list([{ time: 3725, title: 'Late' }], { start: 0, end: 4000 }, []), '0:00 Intro\n1:02:05 Late');
  assert.deepEqual(C.add([{ time: 5, title: 'A' }], 2), [{ time: 2, title: 'Chapter 2' }, { time: 5, title: 'A' }]);
});
