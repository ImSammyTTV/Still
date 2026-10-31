// A share link as a QR code, so it opens on a phone pointed at the screen. Still makes the code; this page shows it.
const link = String((window.__STILL_PARAMS__ || {}).link || '');
$('#link').textContent = link; $('#link').title = link;
still.invoke('qr:svg', link).then((svg) => { $('#code').innerHTML = svg; }).catch((error) => { $('#code').textContent = String(error); });
$('#copy').onclick = () => navigator.clipboard.writeText(link).then(() => toast('Link copied')).catch(() => toast('Couldn’t copy the link'));
$('#close').onclick = () => still.send('window:close');
addEventListener('keydown', (e) => { if (e.key === 'Escape') still.send('window:close'); });
applyTheme().catch(() => {});
refreshIcons();
