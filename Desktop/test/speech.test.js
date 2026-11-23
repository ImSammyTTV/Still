const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../web/shared/speech.js');

test('the sound goes out as a 16-bit mono WAV file', () => {
  const file = S.wav(new Float32Array([0, 1, -1, 2]), 16000), view = new DataView(file.buffer);
  assert.equal(String.fromCharCode(...file.slice(0, 4)), 'RIFF');
  assert.equal(String.fromCharCode(...file.slice(8, 12)), 'WAVE');
  assert.equal(file.length, 44 + 8);
  assert.equal(view.getUint16(22, true), 1, 'one channel');
  assert.equal(view.getUint32(24, true), 16000);
  assert.equal(view.getUint32(40, true), 8);
  assert.deepEqual([0, 1, 2, 3].map((i) => view.getInt16(44 + i * 2, true)), [0, 32767, -32768, 32767], 'loud sound is clipped, not wrapped');
});

test('the clip is sent in pieces of at most five minutes', () => {
  assert.deepEqual(S.pieces({ start: 10, end: 700 }), [{ start: 10, end: 310 }, { start: 310, end: 610 }, { start: 610, end: 700 }]);
  assert.deepEqual(S.pieces({ start: 0, end: 20 }), [{ start: 0, end: 20 }]);
  assert.deepEqual(S.pieces({ start: 0, end: 0 }), []);
});

test('speech becomes captions in the recording’s time, replacing an earlier transcription', () => {
  const mine = { start: 1, end: 2, text: 'Title', position: 'top', size: 'large' };
  const old = { start: 5, end: 6, text: 'old', position: 'bottom', size: 'medium', speech: true };
  const results = [{ offset: 0, segments: [{ start: 0.5, end: 2, text: 'Hello there.' }] }, { offset: 300, segments: [{ start: 1, end: 3, text: 'Second piece.' }] }];
  const out = S.toCaptions([mine, old], results, { start: 0, end: 400 });
  assert.deepEqual(out.map((c) => c.text), ['Hello there.', 'Title', 'Second piece.']);
  assert.deepEqual([out[2].start, out[2].end], [301, 303]);
  assert.ok(out.filter((c) => c.speech).length === 2 && !out.includes(old));
  assert.equal(S.transcript(out), 'Hello there. Second piece.');
});

test('long speech is split at words into short captions sharing its time', () => {
  const words = Array.from({ length: 40 }, (_, i) => `word${i}`).join(' ');
  const parts = S.split({ start: 0, end: 10, text: words });
  assert.ok(parts.length > 1 && parts.every((p) => p.text.length <= S.LONGEST));
  assert.equal(parts.map((p) => p.text).join(' '), words);
  assert.equal(parts[0].start, 0); assert.ok(Math.abs(parts[parts.length - 1].end - 10) < 1e-9);
  const kept = S.toCaptions([], [{ offset: 0, segments: [{ start: 8, end: 12, text: 'Past the end' }] }], { start: 0, end: 10 });
  assert.deepEqual([kept[0].start, kept[0].end], [8, 10], 'kept inside the clip');
});
