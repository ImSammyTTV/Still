// Corner card offering a downloaded-on-demand update; Install shows progress until Still restarts.
const info = window.__STILL_PARAMS__ || {};
applyTheme();
$('#title').textContent = `Still ${info.version} is available`;
$('#sub').textContent = `You have ${info.current}. It installs in under a minute.`;
$('#later').onclick = () => still.send('window:close');
$('#install').onclick = () => {
  $('#install').disabled = true; $('#later').remove();
  $('#install').textContent = 'Downloading…';
  still.send('update:install');
};
still.on('update:status', (status) => {
  if (status.state === 'downloading') $('#install').textContent = `Downloading… ${status.progress || 0}%`;
  if (status.state === 'error') { $('#sub').textContent = status.error; $('#install').disabled = false; $('#install').textContent = 'Try Again'; }
});
