const id = params.get('id');
let item, prefs, timer, hovering = false;

function leave(after) {
  $('#card').classList.add('leaving');
  setTimeout(() => (after ? after() : still.send('preview:close')), 220);
}
function schedule() {
  clearTimeout(timer);
  if (!prefs.quickAccess.autoClose || hovering) return;
  timer = setTimeout(() => leave(), prefs.quickAccess.closeAfter * 1000);
}

(async () => {
  prefs = await applyTheme();
  item = await still.invoke('library:get', id);
  if (!item) return still.send('preview:close');
  document.body.classList.toggle('right', prefs.quickAccess.side === 'right');
  const url = `${still.fileUrl(item.path)}?t=${item.modified || item.created}`;
  if (item.kind === 'recording') {
    const video = el('video', { class: 'media', src: url, muted: true, loop: true, playsinline: true });
    video.muted = true; $('#media').append(video, el('span', { class: 'badge' }, StillGeometry.formatDuration(item.duration || 0)));
    $('#card').addEventListener('mouseenter', () => video.play().catch(() => {}));
    $('#card').addEventListener('mouseleave', () => video.pause());
    $('#edit').title = 'Open'; $('#edit').innerHTML = icon('play'); $('#pin').remove();
  } else $('#media').append(el('img', { class: 'media', src: item.thumb ? `${still.fileUrl(item.thumb)}?t=${item.modified || item.created}` : url, decoding: 'async', draggable: 'false' }));
  refreshIcons();
  if (params.get('sound') === '1') shutter();
  schedule();
})();

$('#card').addEventListener('mouseenter', () => { hovering = true; clearTimeout(timer); });
$('#card').addEventListener('mouseleave', () => { hovering = false; schedule(); });
$('#close').onclick = () => leave();
$('#copy').onclick = async () => { await still.invoke('library:copy', id); leave(); };
$('#save').onclick = async () => { try { await still.invoke('library:save', id); leave(); } catch (e) { toast(`Couldn’t save: ${e}`); } };
$('#upload').onclick = async () => { $('#upload').disabled = true; try { await still.invoke('cloud:upload', id); leave(); } catch { $('#upload').disabled = false; } };
$('#edit').onclick = () => item.kind === 'recording' ? (still.invoke('library:open', id), leave()) : still.send('preview:edit', id);
$('#pin').onclick = () => { still.invoke('library:pin', id); leave(); };
$('#trash').onclick = () => leave(() => still.invoke('library:delete', id));
$('#media').addEventListener('dblclick', () => $('#edit').click());
dragOut($('#media'), () => { still.send('library:drag', id); setTimeout(() => leave(), 400); });
addEventListener('keydown', (e) => { if (e.key === 'Escape') leave(); });
