// Corner card offering an update; Install shows a progress bar until Still restarts.
const info = window.__STILL_PARAMS__ || {};
applyTheme();
$('#title').textContent = `Still ${info.version}`;
$('#sub').textContent = `You have ${info.current}. Installs in under a minute.`;
$('#later').onclick = () => still.send('window:close');
$('#install').onclick = () => {
  $('#install').disabled = true; $('#later').hidden = true;
  $('#install').textContent = 'Downloading…'; $('.card').classList.add('busy');
  $('#sub').classList.remove('error'); $('#sub').textContent = 'Still restarts when it’s ready.';
  still.send('update:install');
};
still.on('update:status', (status) => {
  if (status.state === 'downloading') {
    const progress = status.progress || 0;
    $('#bar').style.width = `${progress}%`; $('#install').textContent = `Downloading… ${progress}%`;
  }
  if (status.state === 'installing') { $('#bar').style.width = '100%'; $('#install').textContent = 'Installing…'; }
  if (status.state === 'error') {
    $('.card').classList.remove('busy'); $('#later').hidden = false;
    $('#sub').classList.add('error'); $('#sub').textContent = status.error;
    $('#install').disabled = false; $('#install').textContent = 'Try Again';
  }
});
