// Finds the private details in recognised text (email addresses, card numbers, keys and tokens, IP addresses and
// phone numbers) so the editor can cover them in one go. The Mac app's PrivateInfo follows the same rules and shares
// these tests' cases. Positions are UTF-16 offsets into the text, as both platforms count them.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillPrivate = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const OCTET = '(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)';
  // In order of priority: a part of the text claimed by one kind isn't looked at again by a later one.
  const RULES = [
    ['email', /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g],
    ['key', /\b(?:[sprk]k_(?:live|test)_[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,})/g],
    ['key', /[A-Za-z0-9_-]{24,}/g],
    ['card', /\b(?:\d[ -]?){12,18}\d\b/g],
    ['ip', new RegExp(`\\b(?:${OCTET}\\.){3}${OCTET}\\b`, 'g')],
    ['phone', /(?:\+\d{1,3}[ .-]?)?(?:\(\d{2,4}\)[ .-]?)?\d{2,4}(?:[ .-]\d{2,4}){1,4}|\+\d{9,15}/g],
  ];

  const digits = (text) => text.replace(/\D/g, '');

  // The card-number checksum, which rules out most long numbers that only look like cards.
  function luhn(number) {
    let sum = 0;
    for (let i = 0; i < number.length; i++) {
      let d = Number(number[number.length - 1 - i]);
      if (i % 2) { d *= 2; if (d > 9) d -= 9; }
      sum += d;
    }
    return sum % 10 === 0;
  }

  // Whether a match of a kind really is one: a long run of letters and digits counts as a key only when it mixes
  // upper case, lower case and digits, as generated secrets do and words, file names and hashes in prose rarely do.
  function accepts(kind, text, rule) {
    if (kind === 'key' && rule === 2) return /[a-z]/.test(text) && /[A-Z]/.test(text) && /\d/.test(text);
    if (kind === 'card') { const n = digits(text); return n.length >= 13 && n.length <= 19 && luhn(n); }
    if (kind === 'phone') { const n = digits(text).length; return n >= 9 && n <= 15; }
    return true;
  }

  // [{ kind, start, end }] for every private detail in `text`, in reading order.
  function find(text) {
    const found = [];
    RULES.forEach(([kind, pattern], rule) => {
      pattern.lastIndex = 0;
      for (const m of String(text || '').matchAll(pattern)) {
        const start = m.index, end = m.index + m[0].length;
        if (!accepts(kind, m[0], rule)) continue;
        if (found.some((f) => f.start < end && f.end > start)) continue;
        found.push({ kind, start, end });
      }
    });
    return found.sort((a, b) => a.start - b.start);
  }

  // Boxes to cover on a picture, from recognised lines of words ({ text, box: { x0, y0, x1, y1 } }): each detail's
  // words joined into one box, with a little room so no edge of a letter shows.
  function boxes(lines, pad = 3) {
    const out = [];
    for (const words of lines || []) {
      let text = '';
      const spans = words.map((w) => { const start = text ? text.length + 1 : 0; text += (text ? ' ' : '') + w.text; return { start, end: text.length, box: w.box }; });
      for (const hit of find(text)) {
        const covered = spans.filter((s) => s.start < hit.end && s.end > hit.start);
        if (!covered.length) continue;
        const x0 = Math.min(...covered.map((s) => s.box.x0)), y0 = Math.min(...covered.map((s) => s.box.y0));
        const x1 = Math.max(...covered.map((s) => s.box.x1)), y1 = Math.max(...covered.map((s) => s.box.y1));
        out.push({ kind: hit.kind, x: x0 - pad, y: y0 - pad, w: x1 - x0 + pad * 2, h: y1 - y0 + pad * 2 });
      }
    }
    return out;
  }

  return { find, boxes, luhn };
});
