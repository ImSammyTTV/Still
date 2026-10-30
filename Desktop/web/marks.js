// Click ripples and keys over the recorded area. This window only shows them: keys are held here for the moment
// they're on screen and never logged or stored.
let keys = [];

function drawKeys() {
  keys = StillRecordingMarks.visibleKeys(keys, null, Date.now());
  $('#keys').replaceChildren(...keys.map((key) => el('span', { class: 'key' }, key.text)));
}

still.on('marks:click', ({ x, y }) => {
  const ripple = el('div', { class: 'ripple', style: `left:${x * 100}%;top:${y * 100}%` });
  $('#clicks').append(ripple);
  setTimeout(() => ripple.remove(), 600);
});

still.on('marks:keys', (text) => {
  keys = StillRecordingMarks.visibleKeys(keys, text, Date.now());
  drawKeys();
  setTimeout(drawKeys, StillRecordingMarks.KEY_LIFE + 20);
});
