let kind = 'all';
const images = new Map();
// Screenshots picked with Ctrl/⌘-click (or Shift-click) to combine, in the order they were picked.
let picks = [];
const tiles = new Map();
function showPicks() {
  for (const [id, tile] of tiles) { const n = picks.indexOf(id); tile.classList.toggle('picked', n >= 0); tile.querySelector('.pick-number').textContent = n >= 0 ? n + 1 : ''; }
  $('#pickbar').classList.toggle('show', picks.length > 0);
  $('#pickCount').textContent = picks.length === 1 ? '1 screenshot · pick one more' : `${picks.length} screenshots`;
  $('#combineSide').disabled = $('#combineStack').disabled = picks.length < 2;
}
function togglePick(item) {
  if (item.kind === 'recording') return toast('Only screenshots can be combined');
  picks = picks.includes(item.id) ? picks.filter((id) => id !== item.id) : [...picks, item.id];
  showPicks();
}
function star(item, on) { still.invoke('library:star', item.id, on).then(() => toast(on ? 'Starred' : 'Star removed')).catch((error) => toast(explain(error))); }
async function combinePicks(vertical) {
  toast('Combining…');
  try { await still.invoke('library:combine', picks, vertical); picks = []; showPicks(); }
  catch (error) { toast(explain(error)); }
}
$('#combineSide').onclick = () => combinePicks(false);
$('#combineStack').onclick = () => combinePicks(true);
$('#pickClear').onclick = () => { picks = []; showPicks(); };
addEventListener('keydown', (e) => { if (e.key === 'Escape' && picks.length && e.target.tagName !== 'INPUT') { picks = []; showPicks(); } });
const sizeLabel = (item) => item.kind === 'recording' ? StillGeometry.formatDuration(item.duration || 0) : item.width ? `${item.width} × ${item.height}` : '';
const when = (time) => new Date(time).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

// Recordings load their first frame only when their tile comes near the window, so a long History opens at once
// instead of reading every video file up front.
const nearby = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const video = entry.target; nearby.unobserve(video);
    video.preload = 'metadata'; video.src = video.dataset.src;
  }
}, { rootMargin: '400px' });

async function load() {
  const items = await still.invoke('library:list', { query: $('#search').value, kind });
  const grid = $("#grid"); grid.replaceChildren(); images.clear(); tiles.clear(); nearby.disconnect();
  picks = picks.filter((id) => items.some((i) => i.id === id && i.kind !== 'recording'));
  if (!items.length) {
    grid.append(el('div', { class: 'empty', html: `${icon('images')}<div>${$('#search').value ? 'No captures match your search.' : kind === 'starred' ? 'Star a capture to find it here.' : 'Your captures will appear here.'}</div>` }));
    return refreshIcons();
  }
  for (const item of items) {
    const url = `${still.fileUrl(item.path)}?t=${item.modified || item.created}`;
    const media = item.kind === 'recording' ? el('video', { 'data-src': `${url}#t=0.1`, muted: true, preload: 'none' }) : el('img', { src: item.thumb ? `${still.fileUrl(item.thumb)}?t=${item.modified || item.created}` : url, loading: 'lazy', decoding: 'async', draggable: 'false' });
    if (item.kind !== 'recording') images.set(item.id, media);
    if (item.kind === 'recording') { nearby.observe(media); media.muted = true; media.addEventListener('mouseenter', () => media.play().catch(() => {})); media.addEventListener('mouseleave', () => { media.pause(); if (media.src) media.currentTime = 0.1; }); }
    const title = el('div', { class: 'title', title: 'Double-click to rename' }, item.title);
    title.addEventListener('dblclick', (e) => { e.stopPropagation(); title.contentEditable = 'true'; title.focus(); document.getSelection().selectAllChildren(title); });
    title.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); title.blur(); } if (e.key === 'Escape') { title.textContent = item.title; title.blur(); } });
    title.addEventListener('blur', () => { title.contentEditable = 'false'; const next = title.textContent.trim(); if (next && next !== item.title) still.invoke('library:rename', item.id, next); else title.textContent = item.title; });
    const tools = el('div', { class: 'tools' }, [
      el('button', { title: 'Copy', html: icon('copy'), onclick: (e) => { e.stopPropagation(); still.invoke('library:copy', item.id).then(() => toast('Copied')); } }),
      el('button', { title: 'Show in folder', html: icon('folder-open'), onclick: (e) => { e.stopPropagation(); still.invoke('library:reveal', item.id); } }),
      el('button', { title: 'Delete', html: icon('trash-2'), onclick: async (e) => { e.stopPropagation(); await still.invoke('library:delete', item.id); } })
    ]);
    const tile = el('div', { class: 'tile' }, [
      el('div', { class: 'thumb' }, [media, el('span', { class: 'pick-number' }),
        el('button', { class: `star${item.starred ? ' on' : ''}`, title: item.starred ? 'Unstar' : 'Star to find it again quickly', 'aria-label': item.starred ? 'Unstar' : 'Star', 'aria-pressed': String(!!item.starred), html: icon('star'), onclick: (e) => { e.stopPropagation(); star(item, !item.starred); } }), el('span', { class: 'kind', html: `${icon(item.kind === 'recording' ? 'video' : 'image')}${item.kind === 'recording' ? 'Video' : 'Image'}` }), tools]),
      el('div', { class: 'meta' }, [title, el('div', { class: 'sub' }, `${when(item.created)}${sizeLabel(item) ? ' · ' + sizeLabel(item) : ''}`)])
    ]);
    // A capture whose file has gone (moved, renamed or deleted outside Still) says so instead of showing a broken picture.
    media.addEventListener('error', () => { if (media.getAttribute('src')) { tile.classList.add('missing'); tile.title = 'This file has been moved or deleted'; } });
    tiles.set(item.id, tile);
    tile.addEventListener('click', (e) => { if (e.ctrlKey || e.metaKey || e.shiftKey) { e.preventDefault(); togglePick(item); } });
    tile.addEventListener('dblclick', () => still.invoke('library:open', item.id));
    dragOut(tile, () => still.send('library:drag', item.id));
    tile.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      popupMenu({ x: e.clientX, y: e.clientY }, [
        { label: item.kind === 'recording' ? 'Trim and Export…' : 'Annotate', icon: item.kind === 'recording' ? 'scissors' : 'pencil', action: () => still.invoke('library:open', item.id) },
        ...(item.kind === 'recording' ? [{ label: 'Open in Default Player', icon: 'play', action: () => still.invoke('library:play', item.id) }] : []),
        { label: item.starred ? 'Unstar' : 'Star', icon: 'star', action: () => star(item, !item.starred) },
        { label: 'Copy', icon: 'copy', action: () => still.invoke('library:copy', item.id) },
        { label: 'Save', icon: 'download', action: () => still.invoke('library:save', item.id).then(() => toast('Saved'), (e) => toast(`Couldn’t save: ${explain(e)}`)) },
        { label: 'Save As…', icon: 'folder-down', action: () => still.invoke('library:saveAs', item.id).then((file) => file && toast('Saved'), (e) => toast(`Couldn’t save: ${explain(e)}`)) },
        { label: 'Upload and Copy Link', icon: 'cloud-upload', action: () => still.invoke('cloud:upload', item.id).then((result) => toast(String(result).startsWith('http') ? 'Link copied' : 'Saved to iCloud Drive')).catch((error) => toast(explain(error))) },
        { label: 'Upload and Show QR Code', icon: 'qr-code', action: () => still.invoke('library:qr', item.id).catch((error) => toast(explain(error))) },
        ...(item.kind === 'recording' ? [] : picks.length >= 2 && picks.includes(item.id)
          ? [{ label: `Combine ${picks.length} Side by Side`, icon: 'columns-2', action: () => combinePicks(false) }, { label: `Combine ${picks.length} Top to Bottom`, icon: 'rows-2', action: () => combinePicks(true) }]
          : [{ label: picks.includes(item.id) ? 'Remove from Combine' : 'Select to Combine', icon: 'copy-plus', action: () => togglePick(item) }]),
        ...(item.kind === 'recording' ? [] : [{ label: 'Pin to Screen', icon: 'pin', action: () => still.invoke('library:pin', item.id) }]),
        { label: 'Show in Folder', icon: 'folder-open', action: () => still.invoke('library:reveal', item.id) },
        '-',
        { label: 'Delete', icon: 'trash-2', action: () => still.invoke('library:delete', item.id) }
      ]);
    });
    grid.append(tile);
  }
  showPicks();
  refreshIcons();
}

$('#filter').addEventListener('click', (e) => {
  const b = e.target.closest('[data-kind]'); if (!b) return;
  kind = b.dataset.kind; $$('#filter button').forEach((x) => x.classList.toggle('active', x === b)); load();
});
let searchTimer;
$('#search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(load, 150); });
still.on('library:changed', load);
still.on('library:thumb', ({ id, thumb }) => { const image = images.get(id); if (image) image.src = `${still.fileUrl(thumb)}?t=${Date.now()}`; });
applyTheme().then((prefs) => { if (prefs.platform !== 'darwin') addWindowControls(); load(); });
