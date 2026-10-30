let kind = 'all';
const sizeLabel = (item) => item.kind === 'recording' ? StillGeometry.formatDuration(item.duration || 0) : item.width ? `${item.width} × ${item.height}` : '';
const when = (time) => new Date(time).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

async function load() {
  const items = await still.invoke('library:list', { query: $('#search').value, kind });
  const grid = $('#grid'); grid.replaceChildren();
  if (!items.length) {
    grid.append(el('div', { class: 'empty', html: `${icon('images')}<div>${$('#search').value ? 'No captures match your search.' : 'Your captures will appear here.'}</div>` }));
    return refreshIcons();
  }
  for (const item of items) {
    const url = `${still.fileUrl(item.path)}?t=${item.modified || item.created}`;
    const media = item.kind === 'recording' ? el('video', { src: url, muted: true, preload: 'metadata' }) : el('img', { src: url, loading: 'lazy', draggable: 'false' });
    if (item.kind === 'recording') { media.muted = true; media.addEventListener('mouseenter', () => media.play().catch(() => {})); media.addEventListener('mouseleave', () => { media.pause(); media.currentTime = 0; }); }
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
      el('div', { class: 'thumb' }, [media, el('span', { class: 'kind', html: `${icon(item.kind === 'recording' ? 'video' : 'image')}${item.kind === 'recording' ? 'Video' : 'Image'}` }), tools]),
      el('div', { class: 'meta' }, [title, el('div', { class: 'sub' }, `${when(item.created)}${sizeLabel(item) ? ' · ' + sizeLabel(item) : ''}`)])
    ]);
    tile.addEventListener('dblclick', () => still.invoke('library:open', item.id));
    dragOut(tile, () => still.send('library:drag', item.id));
    tile.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      popupMenu({ x: e.clientX, y: e.clientY }, [
        { label: item.kind === 'recording' ? 'Trim and Export…' : 'Annotate', icon: item.kind === 'recording' ? 'scissors' : 'pencil', action: () => still.invoke('library:open', item.id) },
        ...(item.kind === 'recording' ? [{ label: 'Open in Default Player', icon: 'play', action: () => still.invoke('library:play', item.id) }] : []),
        { label: 'Copy', icon: 'copy', action: () => still.invoke('library:copy', item.id) },
        { label: 'Save', icon: 'download', action: () => still.invoke('library:save', item.id).then(() => toast('Saved'), (e) => toast(`Couldn’t save: ${e}`)) },
        { label: 'Save As…', icon: 'folder-down', action: () => still.invoke('library:saveAs', item.id).then((file) => file && toast('Saved'), (e) => toast(`Couldn’t save: ${e}`)) },
        { label: 'Upload and Copy Link', icon: 'cloud-upload', action: () => still.invoke('cloud:upload', item.id).then(() => toast('Link copied')).catch((error) => toast(String(error))) },
        ...(item.kind === 'recording' ? [] : [{ label: 'Pin to Screen', icon: 'pin', action: () => still.invoke('library:pin', item.id) }]),
        { label: 'Show in Folder', icon: 'folder-open', action: () => still.invoke('library:reveal', item.id) },
        '-',
        { label: 'Delete', icon: 'trash-2', action: () => still.invoke('library:delete', item.id) }
      ]);
    });
    grid.append(tile);
  }
  refreshIcons();
}

$('#filter').addEventListener('click', (e) => {
  const b = e.target.closest('[data-kind]'); if (!b) return;
  kind = b.dataset.kind; $$('#filter button').forEach((x) => x.classList.toggle('active', x === b)); load();
});
let searchTimer;
$('#search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(load, 150); });
still.on('library:changed', load);
applyTheme().then((prefs) => { if (prefs.platform !== 'darwin') addWindowControls(); load(); });
