// Storyboard: one picture of a whole video, a grid of frames each labelled with its time in the finished video (and
// its chapter's name when there are chapters). With chapters it shows each chapter's first frame; without, `count`
// frames spread evenly through what's kept. Shared by the video editor and the tests; the Mac app's VideoStoryboard
// follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./trim.js'), require('./chapters.js'));
  else root.StillStoryboard = factory(root.StillTrim, root.StillChapters);
})(typeof self !== 'undefined' ? self : this, function (Trim, Chapters) {
  // The frames to show: [{ time (the recording's), label }], at most `max`.
  function frames(clip, cuts, chapters, { count = 12, max = 24, speed = 1, skims = [] } = {}) {
    const kept = Trim.kept(clip, cuts || [], skims), total = Trim.keptLength(clip, cuts || [], skims);
    if (total <= 0) return [];
    const inside = (chapters || []).filter((c) => c.time >= clip.start && c.time <= clip.end && !(cuts || []).some((x) => c.time >= x.start && c.time < x.end))
      .sort((a, b) => a.time - b.time);
    // Whole seconds, or tenths on a video under 20 s, where whole seconds would repeat.
    const time = (t) => { const at = Trim.outputAt(t, kept) / Math.max(1, speed); return total / Math.max(1, speed) < 20 ? Trim.clock(at) : Chapters.stamp(at); };
    const label = (t, name) => `${time(t)}${name ? `  ${name}` : ''}`;
    if (inside.length) return inside.slice(0, max).map((c) => ({ time: Math.min(clip.end - 0.05, c.time + 0.05), label: label(c.time, String(c.title || '').trim()) }));
    const n = Math.max(1, Math.min(max, count));
    return Array.from({ length: n }, (_, i) => { const t = Trim.sourceAt(total * (i + 0.5) / n, kept); return { time: t, label: label(t) }; });
  }

  // The sheet: tiles `tile` wide in up to `columns` columns, a label strip under each, `gap` around them.
  function layout(n, width, height, { tile = 480, columns = 4, gap = 16, strip = 34 } = {}) {
    const cols = Math.max(1, Math.min(columns, n)), rows = Math.ceil(n / cols);
    const th = Math.round(tile * height / Math.max(1, width));
    return { cols, rows, tileWidth: tile, tileHeight: th, strip, gap, width: cols * tile + (cols + 1) * gap, height: rows * (th + strip) + (rows + 1) * gap };
  }

  return { frames, layout };
});
