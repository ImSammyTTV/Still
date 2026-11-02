let opacity = 1, levelTimer, dragFrom = null;
$('#img').crossOrigin = 'anonymous';
$('#img').src = still.fileUrl(params.get('file'));
refreshIcons();
const show = (text) => { $('#level').textContent = text; $('#level').classList.add('show'); clearTimeout(levelTimer); levelTimer = setTimeout(() => $('#level').classList.remove('show'), 900); };

// Scroll to resize, Ctrl+scroll to change opacity, drag anywhere to move.
addEventListener('wheel', (e) => {
  if (e.ctrlKey || e.metaKey) { opacity = Math.min(1, Math.max(0.15, opacity - Math.sign(e.deltaY) * 0.05)); still.send('pin:opacity', opacity); show(`Opacity ${Math.round(opacity * 100)}%`); }
  else still.send('pin:resize', e.deltaY < 0 ? 0.05 : -0.05);
});
$('#img').addEventListener('mousedown', (e) => { if (e.button === 0) dragFrom = { x: e.screenX, y: e.screenY }; });
addEventListener('mousemove', (e) => {
  if (!dragFrom) return;
  still.send('pin:move', e.screenX - dragFrom.x, e.screenY - dragFrom.y);
  dragFrom = { x: e.screenX, y: e.screenY };
});
addEventListener('mouseup', () => { dragFrom = null; });
addEventListener('keydown', (e) => {
  const step = e.shiftKey ? 10 : 1;
  if (e.key === 'Escape') still.send('window:close');
  else if (e.key === '=' || e.key === '+') still.send('pin:resize', 0.1);
  else if (e.key === '-') still.send('pin:resize', -0.1);
  else if (e.key === 'ArrowLeft') still.send('pin:move', -step, 0);
  else if (e.key === 'ArrowRight') still.send('pin:move', step, 0);
  else if (e.key === 'ArrowUp') still.send('pin:move', 0, -step);
  else if (e.key === 'ArrowDown') still.send('pin:move', 0, step);
});
addEventListener('contextmenu', (e) => {
  e.preventDefault();
  popupMenu({ x: e.clientX, y: e.clientY }, [
    { label: 'Copy Image', icon: 'copy', action: () => still.invoke('editor:copy', imageData()) },
    { label: 'Lock (Click Through)', icon: 'lock', action: lock },
    '-',
    { label: 'Close', icon: 'x', action: () => still.send('window:close') }
  ]);
});
function imageData() {
  const img = $('#img'), c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
  c.getContext('2d').drawImage(img, 0, 0); return c.toDataURL();
}
function lock() { still.send('pin:lock', true); }
$('#close').onclick = () => still.send('window:close');
$('#lock').onclick = lock;
