let kind = 'all';
// Find Similar: the screenshot the grid is showing look-alikes of, or null for the usual History.
let similarTo = null;
function findSimilar(item) { similarTo = item; $('#grid').scrollTop = 0; load(); }
// Describe Image: Gemini writes a short description (with the user's own key), kept with the capture for search.
async function describe(item) {
  toast('Describing…');
  try { const text = await still.invoke('library:describe', item.id); await navigator.clipboard.writeText(text).catch(() => {}); toast(`${text.split('\n')[0]} (copied)`); }
  catch (error) {
    const why = explain(error);
    toast(/Settings/.test(why) ? 'Add a key in Settings → Cloud → Describe Image first' : why);
    if (/Settings/.test(why)) still.invoke('open:settings', 'Cloud').catch(() => {});
  }
}
// Find Similar in a Folder: pictures anywhere in a folder the user picks that look like this capture.
let folderMatches = null;
async function findSimilarInFolder(item) {
  toast('Choose a folder to look in…');
  try {
    const result = await still.invoke('library:similarInFolder', item.id);
    if (!result) return; // No folder chosen.
    folderMatches = { item, ...result }; $('#grid').scrollTop = 0; load();
  } catch (error) { toast(explain(error)); }
}
function showFolderMatches(grid) {
  const m = folderMatches, folderName = m.folder.split(/[\\/]/).filter(Boolean).pop() || m.folder;
  grid.replaceChildren(el('div', { class: 'similar-bar' }, [
    el('span', { html: icon('folder-open') }),
    el('span', {}, `${m.found.length ? `${m.found.length} ${m.found.length === 1 ? 'picture' : 'pictures'} in “${folderName}” look like` : `Nothing in “${folderName}” looks like`} “${m.item.title}”${m.capped ? ' (the first 5,000 pictures were checked)' : ` (${m.scanned} checked)`}`),
    el('button', { class: 'btn', onclick: () => { folderMatches = null; load(); } }, 'Show All')
  ]));
  for (const f of m.found) {
    const tile = el('div', { class: 'tile', title: f.path }, [
      el('div', { class: 'thumb' }, [el('img', { src: still.fileUrl(f.path), loading: 'lazy', decoding: 'async', draggable: 'false' })]),
      el('div', { class: 'meta' }, [el('div', { class: 'title' }, f.name), el('div', { class: 'sub' }, f.distance === 0 ? 'Same picture' : f.distance <= 4 ? 'Very close' : 'Similar')])
    ]);
    tile.addEventListener('dblclick', () => still.invoke('library:folderMatch', f.index, false).catch((e) => toast(explain(e))));
    tile.addEventListener('contextmenu', (e) => { e.preventDefault(); popupMenu({ x: e.clientX, y: e.clientY }, [
      { label: 'Open', icon: 'image', action: () => still.invoke('library:folderMatch', f.index, false) },
      { label: 'Show in Folder', icon: 'folder-open', action: () => still.invoke('library:folderMatch', f.index, true) }]); });
    grid.append(tile);
  }
  refreshIcons();
}
function searchWeb(item) {
  still.invoke('library:searchWeb', item.id).then(() => toast('Image copied. Paste it on the search page (Ctrl+V) to search.')).catch((error) => toast(explain(error)));
}
const images = new Map();
// Deleting moves a capture to the Recycle Bin / Trash, as on the Mac, so it can be put back from there.
const binName = () => (still.platform === 'win32' ? 'Recycle Bin' : 'Trash');
const remove = (item) => still.invoke('library:delete', item.id).then(() => toast(`Moved to the ${binName()}`)).catch((error) => toast(`Couldn’t delete it: ${explain(error)}`));
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
  if (folderMatches) { images.clear(); tiles.clear(); nearby.disconnect(); return showFolderMatches($('#grid')); }
  let items = await still.invoke('library:list', { query: similarTo ? '' : $('#search').value, kind: similarTo ? 'screenshot' : kind });
  let banner = null;
  if (similarTo) {
    const target = items.find((i) => i.id === similarTo.id);
    let found = [];
    try { found = target ? await still.invoke('library:similar', target.id) : []; } catch (error) { toast(explain(error)); }
    const byId = new Map(items.map((i) => [i.id, i]));
    items = target ? [target, ...found.map((f) => byId.get(f.id)).filter(Boolean)] : [];
    const count = items.length - 1;
    banner = el('div', { class: 'similar-bar' }, [
      el('span', { html: icon('images') }),
      el('span', {}, count > 0 ? `${count} ${count === 1 ? 'screenshot looks' : 'screenshots look'} like “${similarTo.title}”` : `Nothing else in your history looks like “${similarTo.title}”`),
      el('button', { class: 'btn', onclick: () => { similarTo = null; load(); } }, 'Show All')
    ]);
  }
  const grid = $("#grid"); grid.replaceChildren(); images.clear(); tiles.clear(); nearby.disconnect();
  if (banner) grid.append(banner);
  picks = picks.filter((id) => items.some((i) => i.id === id && i.kind !== 'recording'));
  if (!items.length) {
    grid.append(el('div', { class: 'empty', html: `${icon('images')}<div>${$('#search').value ? 'No matching captures' : kind === 'starred' ? 'Star a capture to find it here.' : 'No captures yet. Take a screenshot to see it in your capture history.'}</div>` }));
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
      el('button', { title: 'Copy', html: icon('copy'), onclick: (e) => { e.stopPropagation(); still.invoke('library:copy', item.id).then(() => toast(item.kind === 'recording' ? 'Copied recording' : 'Copied image')); } }),
      el('button', { title: 'Show in folder', html: icon('folder-open'), onclick: (e) => { e.stopPropagation(); still.invoke('library:reveal', item.id); } }),
      el('button', { title: `Move to ${binName()}`, html: icon('trash-2'), onclick: (e) => { e.stopPropagation(); remove(item); } })
    ]);
    const tile = el('div', { class: 'tile' }, [
      el('div', { class: 'thumb' }, [media, el('span', { class: 'pick-number' }),
        el('button', { class: `star${item.starred ? ' on' : ''}`, title: item.starred ? 'Unstar' : 'Star to find it again quickly', 'aria-label': item.starred ? 'Unstar' : 'Star', 'aria-pressed': String(!!item.starred), html: icon('star'), onclick: (e) => { e.stopPropagation(); star(item, !item.starred); } }), el('span', { class: 'kind', html: `${icon(item.kind === 'recording' ? 'video' : 'image')}${item.kind === 'recording' ? 'Video' : 'Image'}` }), tools]),
      el('div', { class: 'meta' }, [title, el('div', { class: 'sub', title: item.description || '' }, `${when(item.created)}${sizeLabel(item) ? ' · ' + sizeLabel(item) : ''}${item.description ? ' · Described' : ''}`)])
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
        { label: item.kind === 'recording' ? 'Open Video Editor' : 'Annotate', icon: item.kind === 'recording' ? 'scissors' : 'pencil', action: () => still.invoke('library:open', item.id) },
        ...(item.kind === 'recording' ? [{ label: 'Open in Default Player', icon: 'play', action: () => still.invoke('library:play', item.id) }] : []),
        { label: item.starred ? 'Unstar' : 'Star', icon: 'star', action: () => star(item, !item.starred) },
        { label: 'Copy', icon: 'copy', action: () => still.invoke('library:copy', item.id) },
        { label: 'Save', icon: 'download', action: () => still.invoke('library:save', item.id).then(() => toast('Saved'), (e) => toast(`Couldn’t save: ${explain(e)}`)) },
        { label: 'Save As…', icon: 'folder-down', action: () => still.invoke('library:saveAs', item.id).then((file) => file && toast('Saved'), (e) => toast(`Couldn’t save: ${explain(e)}`)) },
        ...(item.kind === 'recording' ? [] : [
          { label: 'Find Similar', icon: 'images', action: () => findSimilar(item) },
          { label: 'Find Similar in a Folder…', icon: 'folder-open', action: () => findSimilarInFolder(item) },
          { label: item.description ? 'Describe Again' : 'Describe Image', icon: 'sparkles', action: () => describe(item) },
          ...(item.description ? [{ label: 'Copy Description', icon: 'copy', action: () => navigator.clipboard.writeText(item.description).then(() => toast('Description copied')) }] : []),
          { label: 'Search the Web for This Image', icon: 'globe', action: () => searchWeb(item) }]),
        { label: 'Upload and Copy Link', icon: 'cloud-upload', action: () => still.invoke('cloud:upload', item.id).then((result) => toast(String(result).startsWith('http') ? 'Link copied' : 'Saved to iCloud Drive')).catch((error) => toast(explain(error))) },
        { label: 'Upload and Show QR Code', icon: 'qr-code', action: () => still.invoke('library:qr', item.id).catch((error) => toast(explain(error))) },
        ...(item.kind === 'recording' ? [] : picks.length >= 2 && picks.includes(item.id)
          ? [{ label: `Combine ${picks.length} Side by Side`, icon: 'columns-2', action: () => combinePicks(false) }, { label: `Combine ${picks.length} Top to Bottom`, icon: 'rows-2', action: () => combinePicks(true) }]
          : [{ label: picks.includes(item.id) ? 'Remove from Combine' : 'Select to Combine', icon: 'copy-plus', action: () => togglePick(item) }]),
        ...(item.kind === 'recording' ? [] : [{ label: 'Pin to Screen', icon: 'pin', action: () => still.invoke('library:pin', item.id) }]),
        { label: 'Show in Folder', icon: 'folder-open', action: () => still.invoke('library:reveal', item.id) },
        '-',
        { label: `Move to ${binName()}`, icon: 'trash-2', action: () => remove(item) }
      ]);
    });
    grid.append(tile);
  }
  showPicks();
  refreshIcons();
}

$('#filter').addEventListener('click', (e) => {
  const b = e.target.closest('[data-kind]'); if (!b) return;
  kind = b.dataset.kind; similarTo = null; folderMatches = null; $$('#filter button').forEach((x) => x.classList.toggle('active', x === b)); load();
});
let searchTimer;
$('#search').addEventListener('input', () => { similarTo = null; folderMatches = null; clearTimeout(searchTimer); searchTimer = setTimeout(load, 150); });
still.on('library:changed', load);
still.on('library:thumb', ({ id, thumb }) => { const image = images.get(id); if (image) image.src = `${still.fileUrl(thumb)}?t=${Date.now()}`; });
applyTheme().then((prefs) => { if (prefs.platform !== 'darwin') addWindowControls(); load(); });
