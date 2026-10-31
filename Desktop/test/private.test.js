const test = require('node:test');
const assert = require('node:assert/strict');
const { find, boxes, luhn, lineBoxes: StillPrivateLines } = require('../web/shared/private.js');

const kinds = (text) => find(text).map((f) => [f.kind, text.slice(f.start, f.end)]);

// The same cases are in the Mac app's PrivateInfoTests.
test('finds each kind of private detail', () => {
  assert.deepEqual(kinds('Write to jane.doe+work@mail.example.com today'), [['email', 'jane.doe+work@mail.example.com']]);
  assert.deepEqual(kinds('Card 4242 4242 4242 4242 exp 12/29'), [['card', '4242 4242 4242 4242']]);
  assert.deepEqual(kinds('Server 192.168.1.20 is up'), [['ip', '192.168.1.20']]);
  assert.deepEqual(kinds('Call +1 415-555-0132 or (020) 7946 0958'), [['phone', '+1 415-555-0132'], ['phone', '(020) 7946 0958']]);
  assert.deepEqual(kinds('STRIPE_KEY=sk_live_51HxQabcDEF123'), [['key', 'sk_live_51HxQabcDEF123']]);
  assert.deepEqual(kinds('token ghp_A1b2C3d4E5f6G7h8I9j0K1l2'), [['key', 'ghp_A1b2C3d4E5f6G7h8I9j0K1l2']]);
  assert.deepEqual(kinds('secret: Zx81kQp02LmNv7RtYb44WcHs'), [['key', 'Zx81kQp02LmNv7RtYb44WcHs']]);
});

test('leaves ordinary text alone', () => {
  assert.deepEqual(kinds('Meeting on 2026-10-31 at 13:45, room 4, version 1.2.20'), []);
  assert.deepEqual(kinds('Order 4242 4242 4242 4241 shipped'), []); // fails the card checksum, too long for a phone
  assert.deepEqual(kinds('internationalisationcharacteristics'), []); // a long word, not a key
  assert.deepEqual(kinds('Version 999.1.1.1'), []);
});

test('the card checksum', () => {
  assert.equal(luhn('4242424242424242'), true);
  assert.equal(luhn('4242424242424241'), false);
});

test('joins the words of a detail into one padded box per line', () => {
  const w = (text, x0, x1) => ({ text, box: { x0, y0: 10, x1, y1: 30 } });
  const lines = [[w('Mail', 0, 40), w('me:', 45, 70), w('a@b.co', 75, 130)], [w('Card', 0, 40), w('4242', 50, 90), w('4242', 95, 135), w('4242', 140, 180), w('4242', 185, 225)]];
  assert.deepEqual(boxes(lines), [{ kind: 'email', x: 72, y: 7, w: 61, h: 26 }, { kind: 'card', x: 47, y: 7, w: 181, h: 26 }]);
});

test('one padded box per line, for blurring all text', () => {
  const w = (text, x0, x1, y0 = 10, y1 = 30) => ({ text, box: { x0, y0, x1, y1 } });
  assert.deepEqual(StillPrivateLines([[w('Hello', 0, 40), w('world', 45, 90, 8, 31)], []]), [{ x: -3, y: 5, w: 96, h: 29 }]);
});
