// How a video opens and closes: "fade" eases the picture and sound in from nothing and out again, and "rise" does
// the same while the picture grows gently out of its background (and settles back at the end). Times are the
// recording's own; `clip` is the kept part. Shared by the video editor and the tests; the Mac app's
// VideoTransition follows the same rules and shares the test cases.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillTransitions = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const STYLES = ['none', 'fade', 'rise'];
  const DURATION = 0.6; // Seconds.
  const RISE = 0.08; // How much smaller the picture starts when it rises.
  const ease = (x) => { const v = Math.min(1, Math.max(0, x)); return v * v * (3 - 2 * v); };

  // { level, scale } at `time`: level 0 to 1 for the picture's opacity and the sound's volume, and the picture's scale.
  function at(time, clip, opening, closing) {
    const length = Math.max(0, clip.end - clip.start), d = Math.min(DURATION, length / 3);
    const inside = STYLES.includes(opening) && opening !== 'none' && d > 0 ? ease((time - clip.start) / d) : 1;
    const outside = STYLES.includes(closing) && closing !== 'none' && d > 0 ? ease((clip.end - time) / d) : 1;
    const level = Math.min(inside, outside);
    const style = inside <= outside ? opening : closing;
    return { level, scale: style === 'rise' ? 1 - RISE * (1 - level) : 1 };
  }
  const active = (opening, closing) => (STYLES.includes(opening) && opening !== 'none') || (STYLES.includes(closing) && closing !== 'none');

  return { STYLES, DURATION, RISE, at, active };
});
