const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../web/shared/trim');

test('In and Out stay inside the video and cannot cross', () => {
  const d = 10;
  let trim = T.full(d);
  trim = T.setIn(trim, 4, d); assert.equal(trim.start, 4);
  trim = T.setOut(trim, 6, d); assert.equal(trim.end, 6);
  assert.equal(T.setIn(trim, 9, d).start, 6 - T.MIN_LENGTH);
  assert.equal(T.setOut(trim, 1, d).end, 4 + T.MIN_LENGTH);
  assert.equal(T.setIn(trim, -3, d).start, 0);
  assert.equal(T.setOut(trim, 99, d).end, d);
});

test('a clip shorter than the minimum keeps the whole video', () => {
  const d = 0.1, trim = T.full(d);
  assert.deepEqual(T.setIn(trim, 0.05, d), { start: 0, end: d });
  assert.deepEqual(T.setOut(trim, 0.02, d), { start: 0, end: d });
});

test('a full-length trim is recognised', () => {
  assert.ok(T.isFull(T.full(8), 8));
  assert.ok(!T.isFull({ start: 0.5, end: 8 }, 8));
  assert.ok(!T.isFull({ start: 0, end: 7.5 }, 8));
  assert.equal(T.length({ start: 2, end: 3.5 }), 1.5);
});

test('positions on the trim bar map to times and back', () => {
  assert.equal(T.timeAt(50, 200, 8), 2);
  assert.equal(T.timeAt(-10, 200, 8), 0);
  assert.equal(T.timeAt(900, 200, 8), 8);
  assert.equal(T.position(2, 8), 0.25);
  assert.equal(T.position(1, 0), 0);
});

test('times show tenths and roll over correctly', () => {
  assert.equal(T.clock(0), '0:00.0');
  assert.equal(T.clock(3.44), '0:03.4');
  assert.equal(T.clock(59.96), '1:00.0');
  assert.equal(T.clock(125.5), '2:05.5');
});

test('the recorder keeps the source format when it can', () => {
  const only = (...types) => (type) => types.includes(type);
  assert.deepEqual(T.recorderType('mp4', only('video/mp4', 'video/webm')), { type: 'video/mp4', ext: 'mp4' });
  assert.deepEqual(T.recorderType('webm', only('video/mp4', 'video/webm;codecs=vp8,opus')), { type: 'video/webm;codecs=vp8,opus', ext: 'webm' });
  assert.deepEqual(T.recorderType('mp4', only('video/webm')), { type: 'video/webm', ext: 'webm' });
  assert.equal(T.recorderType('mp4', () => false).type, '');
});

test('saved trim points come back only when they still fit the recording', () => {
  assert.deepEqual(T.restore({ start: 1.5, end: 4 }, 10), { start: 1.5, end: 4 });
  assert.deepEqual(T.restore({ start: 2, end: 99 }, 10), { start: 2, end: 10 }); // The file got shorter.
  assert.deepEqual(T.restore(null, 10), { start: 0, end: 10 });
  assert.deepEqual(T.restore({ start: 'x', end: 4 }, 10), { start: 0, end: 10 });
  assert.deepEqual(T.restore({ start: 9.95, end: 12 }, 10), { start: 0, end: 10 }); // Too short to keep.
});

// The same cases are in the Mac app's VideoTimelineTests.
test('cuts are kept sorted, inside the clip and merged where they touch', () => {
  const clip = { start: 1, end: 10 };
  let cuts = T.addCut([], 6, 4, clip);
  assert.deepEqual(cuts, [{ start: 4, end: 6 }]);
  cuts = T.addCut(cuts, 5.5, 7, clip);
  assert.deepEqual(cuts, [{ start: 4, end: 7 }]);
  cuts = T.addCut(cuts, 0, 2, clip);
  assert.deepEqual(cuts, [{ start: 1, end: 2 }, { start: 4, end: 7 }]);
  assert.deepEqual(T.addCut(cuts, 8, 8.05, clip), cuts, 'too short to count');
  assert.deepEqual(T.removeCut(cuts, 0), [{ start: 4, end: 7 }]);
});

test('the kept stretches, their length, and times either side of a cut', () => {
  const clip = { start: 1, end: 10 }, cuts = [{ start: 4, end: 7 }];
  const kept = T.kept(clip, cuts);
  assert.deepEqual(kept, [{ start: 1, end: 4 }, { start: 7, end: 10 }]);
  assert.equal(T.keptLength(clip, cuts), 6);
  assert.equal(T.skip(5, cuts), 7); assert.equal(T.skip(3, cuts), 3);
  assert.equal(T.sourceAt(0, kept), 1); assert.equal(T.sourceAt(3, kept), 4); assert.equal(T.sourceAt(3.5, kept), 7.5); assert.equal(T.sourceAt(99, kept), 10);
  assert.equal(T.outputAt(2, kept), 1); assert.equal(T.outputAt(5, kept), 3); assert.equal(T.outputAt(8, kept), 4);
});

// The same cases are in the Mac app's AudioPausesTests.
test('long silences become cuts that leave a short beat each side', () => {
  const speech = -20, quiet = -70, step = 0.1;
  // 1 s talk, 2 s silence, 1 s talk, 0.5 s silence, 1 s talk.
  const levels = [...Array(10).fill(speech), ...Array(20).fill(quiet), ...Array(10).fill(speech), ...Array(5).fill(quiet), ...Array(10).fill(speech)];
  const cuts = T.pauses(levels, step, { start: 0, end: 5.5 });
  assert.equal(cuts.length, 1, 'the short pause stays');
  assert.ok(Math.abs(cuts[0].start - 1.3) < 1e-9 && Math.abs(cuts[0].end - 2.7) < 1e-9, JSON.stringify(cuts));
  assert.deepEqual(T.pauses(Array(30).fill(speech), step, { start: 0, end: 3 }), [], 'no silence, no cuts');
});

test('loudness levels from samples', () => {
  const lv = T.levelsOf(new Float32Array([1, -1, 1, -1, 0, 0, 0, 0]), 40, 0.1);
  assert.deepEqual(lv.map((v) => Math.round(v)), [0, -120]);
});

// The same cases are in the Mac app's MusicDuckingTests.
test('speech is found, joined across short gaps and padded', () => {
  const s = -20, q = -70;
  const levels = [...Array(5).fill(q), ...Array(10).fill(s), ...Array(2).fill(q), ...Array(5).fill(s), ...Array(20).fill(q), ...Array(5).fill(s)];
  const r = T.speech(levels, 0.1);
  assert.equal(r.length, 2);
  assert.ok(Math.abs(r[0].start - 0.3) < 1e-9 && Math.abs(r[0].end - 2.4) < 1e-9, JSON.stringify(r));
  assert.ok(Math.abs(r[1].start - 4) < 1e-9 && Math.abs(r[1].end - 4.9) < 1e-9, JSON.stringify(r));
});

test('music dips while someone speaks and eases back', () => {
  const r = [{ start: 2, end: 4 }];
  assert.equal(T.duck(1, r), 1);
  assert.equal(T.duck(3, r), 0.3);
  assert.ok(Math.abs(T.duck(1.925, r) - 0.65) < 1e-9);
  assert.ok(Math.abs(T.duck(4.075, r) - 0.65) < 1e-9);
});

test('fast-forwards are sorted, inside the clip, never overlap, and use rate 2, 4 or 8', () => {
  const clip = { start: 0, end: 20 };
  assert.deepEqual(T.normalizeSkims([{ start: 3, end: 8, rate: 8 }, { start: 1, end: 5, rate: 2 }, { start: 18, end: 25, rate: 3 }, { start: 12, end: 12.2, rate: 2 }], clip),
    [{ start: 1, end: 5, rate: 2 }, { start: 5, end: 8, rate: 8 }, { start: 18, end: 20, rate: 4 }]);
  const skims = [{ start: 5, end: 9, rate: 4 }];
  assert.deepEqual(T.addSkim(skims, 2, clip), [{ start: 2, end: 5, rate: 4 }, { start: 5, end: 9, rate: 4 }]);
  assert.deepEqual(T.addSkim(skims, 6, clip), skims);
  assert.deepEqual(T.addSkim(skims, 17, clip, 8), [{ start: 5, end: 9, rate: 4 }, { start: 17, end: 20, rate: 8 }]);
  assert.equal(T.skimAt(6, skims), 4); assert.equal(T.skimAt(9, skims), 1);
});

test('fast-forwards split the kept stretches and shorten the finished video', () => {
  const clip = { start: 0, end: 20 }, cuts = [{ start: 5, end: 7 }], skims = [{ start: 4, end: 10, rate: 4 }];
  const kept = T.kept(clip, cuts, skims);
  assert.deepEqual(kept, [{ start: 0, end: 4 }, { start: 4, end: 5, rate: 4 }, { start: 7, end: 10, rate: 4 }, { start: 10, end: 20 }]);
  assert.equal(T.keptLength(clip, cuts, skims), 15);
  assert.equal(T.outputAt(8, kept), 4.5); assert.equal(T.outputAt(12, kept), 7);
  assert.equal(T.sourceAt(4.5, kept), 8); assert.ok(Math.abs(T.sourceAt(4.1, kept) - 4.4) < 1e-9); assert.equal(T.sourceAt(7, kept), 12);
  assert.deepEqual(T.kept(clip, cuts, []), T.kept(clip, cuts));
});
