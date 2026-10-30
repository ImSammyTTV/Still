// The controls for a scrolling capture. Still grabs and stitches the frames; this page only shows how it's going.
const say = (message) => { $('#message').textContent = message; $('#message').title = message; };
say((window.__STILL_PARAMS__ || {}).message || '');
still.on('scroll:status', ({ frames, width, height, message }) => {
  $('#size').textContent = `${frames} ${frames === 1 ? 'frame' : 'frames'} · ${width} × ${height}`;
  say(message);
});
$('#done').onclick = () => still.send('scroll:stop', true);
$('#cancel').onclick = () => still.send('scroll:stop', false);
