let start = 0, pausedAt = 0, pausedTotal = 0, paused = false;
refreshIcons();
setInterval(() => {
  if (!start) return;
  const now = paused ? pausedAt : performance.now();
  $('#time').textContent = StillGeometry.formatDuration((now - start - pausedTotal) / 1000);
}, 250);
still.on('hud:countdown', (n) => { $('#time').textContent = `Starts in ${n}`; });
still.on('hud:started', () => { start = performance.now(); $('#time').textContent = '0:00'; });
still.on('hud:paused', (value) => {
  paused = value; $('#hud').classList.toggle('paused', value);
  if (value) pausedAt = performance.now(); else pausedTotal += performance.now() - pausedAt;
  $('#pause').innerHTML = icon(value ? 'play' : 'pause'); $('#pause').title = value ? 'Resume' : 'Pause'; refreshIcons();
});
$('#stop').onclick = () => still.send('hud:stop');
$('#pause').onclick = () => still.send('hud:pause');
$('#cancel').onclick = () => still.send('hud:cancel');
$('#restart').onclick = () => still.send('hud:restart');
