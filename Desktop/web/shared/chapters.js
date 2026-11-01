// Chapters: named markers on a recording, and the list they make for a video's description ("0:00 Intro",
// "1:23 Setting up"). Marker times are the recording's own; the list gives times in the finished video, after
// trimming, cuts and export speed, and always starts at 0:00 as video sites expect. Shared by the video editor and
// the tests; the Mac app's VideoChapters follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./trim.js'));
  else root.StillChapters = factory(root.StillTrim);
})(typeof self !== 'undefined' ? self : this, function (Trim) {
  // A new chapter at `time`, numbered after the ones before it.
  const add = (chapters, time) => [...(chapters || []), { time, title: `Chapter ${(chapters || []).length + 1}` }].sort((a, b) => a.time - b.time);

  // 1:05 or 1:02:05.
  const stamp = (seconds) => {
    const s = Math.max(0, Math.floor(seconds + 1e-6)), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, r = s % 60;
    return h ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`;
  };

  // The list, one chapter per line. Chapters in a cut or outside the clip are left out, and ones that land on the
  // same second keep the last name.
  function list(chapters, clip, cuts, speed = 1, skims = []) {
    const kept = Trim.kept(clip, cuts || [], skims);
    const rows = [];
    for (const c of [...(chapters || [])].sort((a, b) => a.time - b.time)) {
      if (c.time < clip.start || c.time > clip.end || (cuts || []).some((x) => c.time >= x.start && c.time < x.end)) continue;
      const at = Math.floor(Trim.outputAt(c.time, kept) / Math.max(1, speed) + 1e-6);
      const title = String(c.title || '').replace(/\s+/g, ' ').trim() || 'Chapter';
      if (rows.length && rows[rows.length - 1].at === at) rows[rows.length - 1].title = title; else rows.push({ at, title });
    }
    if (!rows.length) return '';
    if (rows[0].at > 0) rows.unshift({ at: 0, title: 'Intro' });
    return rows.map((r) => `${stamp(r.at)} ${r.title}`).join('\n');
  }

  // ---- Find Chapters: where the screen changes, named from what it says --------------------------------
  // How different two small greyscale pictures are, 0 (the same) to 1 (black to white everywhere).
  function difference(a, b) {
    const n = Math.min(a.length, b.length);
    if (!n) return 0;
    let sum = 0; for (let i = 0; i < n; i++) sum += Math.abs(a[i] - b[i]);
    return sum / n / 255;
  }
  // The moments the picture changes a lot: `changes[i]` is the difference between the pictures at start + i*step
  // and start + (i+1)*step. A change counts when it stands well clear of the recording's usual movement (six
  // median deviations above its median, and at least `floor`); of changes closer than `gap` seconds, the bigger one
  // wins. Nothing in the first two seconds, which are the opening, not a new part.
  function scenes(changes, step, { gap = 10, floor = 0.08, start = 0 } = {}) {
    const values = (changes || []).filter(Number.isFinite);
    if (!values.length) return [];
    const middle = (list) => { const sorted = [...list].sort((x, y) => x - y); return sorted[Math.floor(sorted.length / 2)]; };
    const median = middle(values), spread = middle(values.map((v) => Math.abs(v - median)));
    const threshold = Math.max(floor, median + 6 * spread);
    const peaks = [];
    changes.forEach((v, i) => {
      if (!(v >= threshold) || v < (changes[i - 1] ?? 0) || v < (changes[i + 1] ?? 0)) return;
      const time = start + (i + 1) * step;
      if (time - start >= 2) peaks.push({ time, v });
    });
    const kept = [];
    for (const p of peaks.sort((x, y) => y.v - x.v || x.time - y.time)) if (kept.every((k) => Math.abs(k - p.time) >= gap)) kept.push(p.time);
    return kept.sort((x, y) => x - y);
  }
  // A chapter's name from the lines of text on screen ({ text, top, height } in pixels): the line in the largest
  // type that reads like a title (three letters or more, mostly letters, not too long), the higher one on a tie.
  // Trailing separators go, and a long one is shortened at a word. '' when nothing fits.
  function pickTitle(rows) {
    const fits = (rows || []).map((r) => ({ ...r, text: String(r.text || '').replace(/\s+/g, ' ').trim().replace(/[\s:|•·–—-]+$/u, '') }))
      .filter((r) => { const letters = (r.text.match(/\p{L}/gu) || []).length; return letters >= 3 && letters / r.text.length >= 0.5 && r.text.length <= 60; });
    if (!fits.length) return '';
    const best = fits.sort((a, b) => b.height - a.height || a.top - b.top)[0].text;
    if (best.length <= 40) return best;
    const cut = best.slice(0, 40), space = cut.lastIndexOf(' ');
    return `${(space > 20 ? cut.slice(0, space) : cut).trim()}…`;
  }
  // The same from recognised lines of words ({ text, box: { x0, y0, x1, y1 } }), as the text reader gives them.
  const titleFrom = (lines) => pickTitle((lines || []).filter((w) => w.length).map((words) => ({
    text: words.map((w) => w.text).join(' '),
    top: Math.min(...words.map((w) => w.box.y0)),
    height: words.reduce((sum, w) => sum + w.box.y1 - w.box.y0, 0) / words.length,
  })));

  return { add, stamp, list, difference, scenes, pickTitle, titleFrom };
});
