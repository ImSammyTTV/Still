// The controls for a scrolling capture. Still grabs and stitches the frames; this page only shows how it's going.
const say = (message) => { $('#message').textContent = message; $('#message').title = message; };
say((window.__STILL_PARAMS__ || {}).message || '');
let auto = false;
const showAuto = () => { $('#auto').textContent = auto ? 'Stop Auto' : 'Auto Scroll'; $('#auto').setAttribute('aria-pressed', String(auto)); };
still.on('scroll:status', ({ frames, width, height, message, auto: on }) => {
  auto = !!on; showAuto();
  $('#size').textContent = `${frames} ${frames === 1 ? 'frame' : 'frames'} · ${width} × ${height}`;
  say(message);
});
$('#done').onclick = () => still.send('scroll:stop', true);
$('#auto').onclick = () => { auto = !auto; showAuto(); still.send('scroll:auto', auto); };
$('#cancel').onclick = () => still.send('scroll:stop', false);
