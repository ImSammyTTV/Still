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
  function list(chapters, clip, cuts, speed = 1) {
    const kept = Trim.kept(clip, cuts || []);
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

  return { add, stamp, list };
});
