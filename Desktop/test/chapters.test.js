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

test('Find Chapters: big changes, at least a gap apart, none in the opening', () => {
  const changes = Array(100).fill(0.01);
  changes[19] = 0.5; changes[21] = 0.3; changes[59] = 0.2; changes[2] = 0.9; changes[79] = 0.05;
  assert.deepEqual(C.scenes(changes, 0.5), [10, 30]);
  assert.deepEqual(C.scenes(changes, 0.5, { start: 5 }), [15, 35]);
  assert.deepEqual(C.scenes(Array(40).fill(0), 0.5), []);
  assert.equal(C.difference([0, 255], [255, 255]), 0.5);
});

test('Find Chapters: the name is the largest title-like line on screen', () => {
  const rows = [{ text: 'File  Edit View', top: 5, height: 12 }, { text: 'Getting Started:', top: 80, height: 32 }, { text: '12:45 PM', top: 3, height: 40 }, { text: 'Welcome back', top: 200, height: 32 }];
  assert.equal(C.pickTitle(rows), 'Getting Started');
  assert.equal(C.pickTitle([{ text: 'Configuring the deployment pipeline for production servers', top: 0, height: 20 }]), 'Configuring the deployment pipeline for…');
  assert.equal(C.pickTitle([{ text: '42 | 17', top: 0, height: 50 }]), '');
  const words = (text, y, h) => text.split(' ').map((t) => ({ text: t, box: { x0: 0, y0: y, x1: 10, y1: y + h } }));
  assert.equal(C.titleFrom([words('small print here', 10, 10), words('Big Heading', 50, 30)]), 'Big Heading');
});
