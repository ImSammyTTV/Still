// Backgrounds behind a capture or a recording: the gradients, the frame size and the painting, shared by the image
// editor, the video editor and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillBackdrop = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const GRADIENTS = {
    paper: ['#F0ECE3', '#DDD5C5'], sage: ['#D9E6C7', '#8DAE91'], midnight: ['#343F53', '#111C2B'], apricot: ['#FFD9AF', '#EAA89D'], ocean: ['#0D5AAA', '#062454'],
    sky: ['#B9DEFF', '#5E9FE8'], mint: ['#C4F3DC', '#5AADA3'], rose: ['#FFE2E6', '#DF8BB0'], coral: ['#FFB09A', '#EF565C'], lavender: ['#D8D2FA', '#8C87DD'],
    iris: ['#B59CED', '#4D3596'], dusk: ['#202255', '#C75F84'], sunrise: ['#F5CF8A', '#EE8782'], gold: ['#F5DA97', '#BC833C'], graphite: ['#4B4C50', '#1D1E20'],
    snow: ['#FFFFFF', '#ECEFF2'], forest: ['#3D8061', '#12362D'], teal: ['#83D9D3', '#1F7C91'], plum: ['#A66AA5', '#3F1B57'], crimson: ['#E58D95', '#9E2045']
  };

  // A video's frame with its background. Padding and corners are shares of the video's shorter side, so a setting
  // looks the same on any recording size; the frame is rounded up to even sizes, which video encoders need.
  const videoFrame = (width, height, bg) => {
    const short = Math.min(width, height);
    const padding = bg && bg.style !== 'none' ? Math.round(short * (bg.padding || 0) / 100) : 0;
    const w = Math.ceil((width + padding * 2) / 2) * 2, h = Math.ceil((height + padding * 2) / 2) * 2;
    return { w, h, x: (w - width) / 2, y: (h - height) / 2, width, height, radius: padding ? Math.round(short * (bg.radius || 0) / 100) : 0 };
  };

  // Fills `size` with the background and leaves the context clipped to the rounded picture at `box`.
  function paint(ctx, size, box, bg, customImage) {
    if (bg.style === 'custom' && customImage) {
      const s = Math.max(size.w / customImage.naturalWidth, size.h / customImage.naturalHeight);
      ctx.drawImage(customImage, (size.w - customImage.naturalWidth * s) / 2, (size.h - customImage.naturalHeight * s) / 2, customImage.naturalWidth * s, customImage.naturalHeight * s);
    } else {
      const [a, b] = GRADIENTS[bg.style] || GRADIENTS.midnight;
      const g = ctx.createLinearGradient(0, 0, size.w, size.h); g.addColorStop(0, a); g.addColorStop(1, b);
      ctx.fillStyle = g; ctx.fillRect(0, 0, size.w, size.h);
    }
    if (bg.shadow) {
      ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = Math.max(20, box.w / 30); ctx.shadowOffsetY = Math.max(6, box.w / 120);
      ctx.fillStyle = '#000'; ctx.beginPath(); ctx.roundRect(box.x, box.y, box.w, box.h, box.radius); ctx.fill(); ctx.restore();
    }
    ctx.beginPath(); ctx.roundRect(box.x, box.y, box.w, box.h, box.radius); ctx.clip();
  }

  return { GRADIENTS, videoFrame, paint };
});
