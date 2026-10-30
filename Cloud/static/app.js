const $ = (id) => document.getElementById(id);
const page = document.body.dataset.page;
const token = document.body.dataset.token;
const state = { csrf: '', shareCSRF: '', filter: 'All', query: '', items: [], shown: 50, total: 0, nextOffset: null, owner: false, point: null, reply: null, pinning: false, commentsSignature: '' };
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const numberFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
const relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
const el = (tag, className, text) => { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node; };
function toast(message) { clearTimeout(state.toastTimer); $('toast').textContent = message; state.toastTimer = setTimeout(() => { $('toast').textContent = ''; }, 4500); }
function size(bytes) { return bytes > 1e9 ? `${numberFormat.format(bytes / 1e9)} GB` : bytes > 1e6 ? `${numberFormat.format(bytes / 1e6)} MB` : `${numberFormat.format(bytes / 1e3)} KB`; }
function clock(seconds) { const value = Math.max(0, Number(seconds) || 0); return `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, '0')}`; }
function since(time) { const minutes = Math.round((time * 1000 - Date.now()) / 60000); return Math.abs(minutes) < 60 ? relativeFormat.format(minutes, 'minute') : Math.abs(minutes) < 1440 ? relativeFormat.format(Math.round(minutes / 60), 'hour') : relativeFormat.format(Math.round(minutes / 1440), 'day'); }
async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.csrf) headers.set('X-CSRF-Token', state.csrf);
  if (options.body && !(options.body instanceof File) && typeof options.body !== 'string') { headers.set('Content-Type', 'application/json'); options.body = JSON.stringify(options.body); }
  const response = await fetch(path, { ...options, headers, credentials: 'same-origin' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) { const error = new Error(data.error || `Request failed (${response.status})`); Object.assign(error, data, { status: response.status }); throw error; }
  return data;
}
function brand(name) { document.querySelectorAll('.brand-name').forEach((node) => { node.textContent = name; }); document.title = name; }
async function copy(text) { try { await navigator.clipboard.writeText(text); toast('Link copied'); } catch { toast('Clipboard access is unavailable. Open the capture and copy its address.'); } }
function showDialog(id) { $(id).showModal(); }
document.querySelectorAll('[data-close]').forEach((button) => button.addEventListener('click', () => $(button.dataset.close).close()));
document.querySelectorAll('dialog').forEach((dialog) => dialog.addEventListener('click', (event) => { if (event.target === dialog) { const rect = dialog.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close(); } }));

if (page === 'login') {
  $('login-page').hidden = false;
  api('/api/health').then((data) => { brand(data.name); $('sso-link').hidden = !data.oidc; }).catch(() => {});
  $('login-form').addEventListener('submit', async (event) => {
    event.preventDefault(); const button = event.submitter; button.disabled = true; button.textContent = 'Signing in…'; $('login-error').textContent = '';
    try { await api('/api/login', { method: 'POST', body: { token: $('login-token').value } }); location.assign('/'); }
    catch (error) { $('login-error').textContent = error.message; $('login-token').focus(); }
    finally { button.disabled = false; button.textContent = 'Sign In'; }
  });
}

if (page === 'dashboard') {
  $('dashboard-page').hidden = false;
  const params = new URLSearchParams(location.search);
  state.query = params.get('q') || ''; state.filter = ['All', 'Images', 'Videos', 'Trash'].includes(params.get('type')) ? params.get('type') : 'All';
  $('search').value = state.query;
  try { const me = await api('/api/me'); state.csrf = me.csrf; brand(me.brand); $('account').textContent = me.user.name; $('team-button').hidden = me.user.role !== 'admin'; }
  catch { location.assign('/'); }
  document.querySelectorAll('[data-filter]').forEach((button) => button.addEventListener('click', () => { state.filter = button.dataset.filter; updateURL(); loadCaptures(); }));
  $('search').addEventListener('input', () => { clearTimeout(state.searchTimer); state.query = $('search').value; state.searchTimer = setTimeout(() => { updateURL(); loadCaptures(); }, 220); });
  $('sort').addEventListener('change', renderCaptures);
  $('load-more').addEventListener('click', async () => { if (state.shown < state.items.length) { state.shown += 50; renderCaptures(); } else if (state.nextOffset !== null) { await loadCaptures(true); state.shown += 50; renderCaptures(); } });
  $('upload-button').addEventListener('click', () => { $('upload-form').reset(); $('upload-error').textContent = ''; showDialog('upload-dialog'); });
  $('upload-file').addEventListener('change', () => { const file = $('upload-file').files[0]; if (file && !$('upload-title').value) $('upload-title').value = file.name.replace(/\.[^.]+$/, ''); });
  $('upload-form').addEventListener('submit', uploadFile);
  $('edit-form').addEventListener('submit', saveEdit);
  $('logout-button').addEventListener('click', async () => { await api('/api/logout', { method: 'POST', body: {} }); location.assign('/'); });
  $('token-button').addEventListener('click', () => { $('connection-url').value = location.origin; $('connection-token').value = ''; showDialog('connection-dialog'); });
  $('generate-token').addEventListener('click', async () => { if (!confirm('Generate a new app token? Existing app connections will need the new token.')) return; const data = await api('/api/token', { method: 'POST', body: {} }); $('connection-token').value = data.token; $('connection-token').focus(); $('connection-token').select(); });
  $('team-button').addEventListener('click', openTeam);
  $('team-form').addEventListener('submit', addMember);
  await loadCaptures();
}
function updateURL() { const url = new URL(location.href); if (state.query) url.searchParams.set('q', state.query); else url.searchParams.delete('q'); if (state.filter !== 'All') url.searchParams.set('type', state.filter); else url.searchParams.delete('type'); history.replaceState(null, '', url); }
async function loadCaptures(append = false) {
  if (!append) { state.shown = 50; state.items = []; state.nextOffset = null; }
  const request = state.request = (state.request || 0) + 1;
  $('captures').setAttribute('aria-busy', 'true'); $('dashboard-error').textContent = '';
  document.querySelectorAll('[data-filter]').forEach((node) => {
    const active = node.dataset.filter === state.filter;
    node.classList.toggle('active', active);
    node.setAttribute('aria-pressed', String(active));
  });
  $('library-title').textContent = state.filter === 'All' ? 'All Captures' : state.filter === 'Images' ? 'Screenshots' : state.filter === 'Videos' ? 'Recordings' : 'Trash';
  const query = new URLSearchParams({ q: state.query, trash: state.filter === 'Trash' ? '1' : '0', offset: append ? String(state.nextOffset || 0) : '0', count: '100', type: state.filter });
  try { const result = await api(`/api/uploads?${query}`); if (request !== state.request) return; state.items = append ? state.items.concat(result.items) : result.items; state.total = result.total ?? state.items.length; state.nextOffset = result.nextOffset ?? null; renderCaptures(); }
  catch (error) { $('dashboard-error').textContent = error.message; }
  finally { $('captures').setAttribute('aria-busy', 'false'); }
}
function renderCaptures() {
  const items = [...state.items];
  const sort = $('sort').value;
  items.sort(sort === 'name' ? (a, b) => a.title.localeCompare(b.title) : sort === 'oldest' ? (a, b) => a.created - b.created : (a, b) => b.created - a.created);
  const fragment = document.createDocumentFragment();
  for (const item of items.slice(0, state.shown)) {
    const card = el('article', 'capture-card');
    const link = el('a', 'capture-thumb'); link.href = item.url; link.target = '_blank'; link.rel = 'noopener'; link.setAttribute('aria-label', `Open ${item.title}`);
    const video = item.mime.startsWith('video/');
    const media = el(video ? 'video' : 'img'); media.src = item.download || item.media; media.width = 300; media.height = 180;
    if (video) { media.preload = 'metadata'; media.muted = true; link.append(media, el('span', 'play', '▷')); } else { media.alt = item.title; media.loading = 'lazy'; link.append(media); }
    const info = el('div', 'capture-info'); info.append(el('h2', '', item.title), el('p', 'capture-date', `${dateFormat.format(new Date(item.created * 1000))} · ${size(item.size)}`));
    if (item.tags.length) { const tags = el('div', 'tags'); item.tags.forEach((tag) => { const button = el('button', 'tag', tag); button.addEventListener('click', () => { state.query = tag; $('search').value = tag; updateURL(); loadCaptures(); }); tags.append(button); }); info.append(tags); }
    const actions = el('div', 'card-actions');
    const add = (title, perform) => { const button = el('button', '', title); button.setAttribute('aria-label', `${title}: ${item.title}`); button.addEventListener('click', perform); actions.append(button); };
    if (state.filter === 'Trash') { add('Restore', async () => { await api(`/api/uploads/${item.id}/restore`, { method: 'POST', body: {} }); toast('Capture restored'); loadCaptures(); }); }
    else {
      add('Copy Link', () => copy(item.url)); add('Settings', () => editCapture(item));
      add('Trash', async () => { if (!confirm(`Move “${item.title}” to Trash? You can restore it later.`)) return; await api(`/api/uploads/${item.id}`, { method: 'DELETE' }); toast('Moved to Trash'); loadCaptures(); });
    }
    info.append(actions); card.append(link, info); fragment.append(card);
  }
  $('captures').replaceChildren(fragment); $('capture-count').textContent = `${new Intl.NumberFormat().format(state.total)} captures`;
  $('empty').hidden = state.total !== 0; $('load-more').hidden = state.shown >= items.length && state.nextOffset === null;
}
async function uploadFile(event) {
  event.preventDefault(); const button = event.submitter, file = $('upload-file').files[0]; if (!file) return;
  button.disabled = true; button.textContent = 'Uploading…'; $('upload-error').textContent = '';
  try {
    const created = await api('/api/uploads', { method: 'POST', body: { title: $('upload-title').value || file.name, mime: file.type || (file.name.endsWith('.heic') ? 'image/heic' : 'image/png'), size: file.size, tags: $('upload-tags').value.split(',').map((x) => x.trim()).filter(Boolean), visibility: $('upload-visibility').value, expiryDays: Number($('upload-expiry').value), password: $('upload-password').value } });
    const target = new URL(created.uploadURL); if (target.origin !== location.origin) throw new Error('The upload server returned an unexpected origin.');
    await api(target.pathname, { method: 'PUT', headers: { 'Content-Type': file.type || 'application/octet-stream' }, body: file });
    $('upload-dialog').close(); await copy(created.url); await loadCaptures();
  } catch (error) { $('upload-error').textContent = error.message; }
  finally { button.disabled = false; button.textContent = 'Upload'; }
}
function editCapture(item) { $('edit-id').value = item.id; $('edit-title').value = item.title; $('edit-tags').value = item.tags.join(', '); $('edit-access').value = item.visibility; $('edit-views').value = item.maxViews; $('edit-expiry').value = 'keep'; $('edit-password').value = ''; $('remove-password').checked = false; $('edit-transcript').value = item.transcript; $('edit-error').textContent = ''; showDialog('edit-dialog'); }
async function saveEdit(event) {
  event.preventDefault(); const button = event.submitter; button.disabled = true; $('edit-error').textContent = '';
  const data = { title: $('edit-title').value, tags: $('edit-tags').value.split(',').map((x) => x.trim()).filter(Boolean), visibility: $('edit-access').value, maxViews: Number($('edit-views').value), transcript: $('edit-transcript').value };
  if ($('edit-expiry').value !== 'keep') data.expiryDays = Number($('edit-expiry').value);
  if ($('remove-password').checked) data.password = ''; else if ($('edit-password').value) data.password = $('edit-password').value;
  try { await api(`/api/uploads/${$('edit-id').value}`, { method: 'PATCH', body: data }); $('edit-dialog').close(); toast('Capture settings saved'); loadCaptures(); }
  catch (error) { $('edit-error').textContent = error.message; }
  finally { button.disabled = false; }
}
async function openTeam() { try { const data = await api('/api/users'); $('team-list').replaceChildren(...data.users.map((user) => { const row = el('div', 'team-member'); row.append(el('span', '', user.name), el('span', '', `${user.role}${user.active ? '' : ' · inactive'}`)); return row; })); showDialog('team-dialog'); } catch (error) { toast(error.message); } }
async function addMember(event) {
  event.preventDefault(); const button = event.submitter; button.disabled = true; $('team-error').textContent = '';
  try { const data = await api('/api/users', { method: 'POST', body: { username: $('team-email').value, name: $('team-name').value, role: $('team-role').value } }); $('team-dialog').close(); $('connection-url').value = location.origin; $('connection-token').value = data.token; showDialog('connection-dialog'); toast('Member created. Share their token privately.'); }
  catch (error) { $('team-error').textContent = error.message; }
  finally { button.disabled = false; }
}

if (page === 'share') {
  $('share-page').hidden = false;
  try { const me = await api('/api/me'); state.csrf = me.csrf; $('guest-name').value = me.user.name; } catch {}
  $('unlock-form').addEventListener('submit', async (event) => { event.preventDefault(); event.submitter.disabled = true; try { await api(`/api/share/${token}/unlock`, { method: 'POST', body: { password: $('link-password').value } }); await loadShare(); } catch (error) { $('unlock-error').textContent = error.message; } finally { event.submitter.disabled = false; } });
  $('comment-form').addEventListener('submit', postComment);
  $('clear-reply').addEventListener('click', () => { state.reply = null; $('replying').hidden = true; });
  $('point-button').addEventListener('click', () => { state.pinning = !state.pinning; $('media-stage').classList.toggle('pinning', state.pinning); $('point-button').setAttribute('aria-pressed', String(state.pinning)); $('point-button').textContent = state.pinning ? 'Click the Image to Place a Pin' : 'Add a Comment Pin'; });
  $('media-stage').addEventListener('click', (event) => {
    if (!state.pinning || !state.media) return;
    const rect = state.media.getBoundingClientRect(); state.point = { x: Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)), y: Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height)) };
    state.pinning = false; $('media-stage').classList.remove('pinning'); $('point-button').textContent = 'Add a Comment Pin'; $('point-button').setAttribute('aria-pressed', 'false'); $('comment-text').focus(); toast('Pin placed. Write your comment.');
  });
  $('transcript-search').addEventListener('input', renderTranscript);
  await loadShare();
  setInterval(() => { if (!document.hidden && state.item) loadComments(); }, 15000);
}
async function loadShare() {
  try {
    const data = await api(`/api/share/${token}`); state.item = data.item; state.owner = data.owner; state.shareCSRF = data.csrf;
    brand(data.brand); document.title = `${data.item.title} — ${data.brand}`; $('share-title').textContent = data.item.title;
    $('share-gate').hidden = true; $('share-main').hidden = false; $('download').hidden = false; $('download').href = data.item.media; $('download').download = data.item.title;
    const video = data.item.mime.startsWith('video/');
    state.media = el(video ? 'video' : 'img'); state.media.src = data.item.media;
    if (video) { state.media.controls = true; state.media.preload = 'metadata'; state.media.playsInline = true; if (data.item.captions) { const track = el('track'); track.kind = 'captions'; track.src = `/api/share/${token}/captions`; track.srclang = 'en'; track.label = 'Captions'; state.media.append(track); } }
    else { state.media.alt = data.item.title; state.media.addEventListener('load', () => renderPins(state.comments || [])); }
    $('media-stage').replaceChildren(state.media); $('timestamp-label').hidden = !video; $('point-button').hidden = video;
    $('share-meta').textContent = `${dateFormat.format(new Date(data.item.created * 1000))} · ${size(data.item.size)}`;
    $('transcript-section').hidden = !data.item.transcript && !data.item.captions; renderTranscript(); await loadComments();
  } catch (error) {
    $('share-main').hidden = true; $('download').hidden = true; $('share-gate').hidden = false;
    $('gate-title').textContent = error.passwordRequired ? 'This capture is protected' : error.status === 410 ? 'This link is no longer available' : error.loginRequired ? 'Sign in to view this capture' : 'Capture unavailable';
    $('gate-message').textContent = error.message; $('unlock-form').hidden = !error.passwordRequired; $('gate-login').hidden = !error.loginRequired;
  }
}
async function loadComments() {
  try {
    const data = await api(`/api/share/${token}/comments`); const signature = JSON.stringify(data.comments); if (signature === state.commentsSignature) return;
    state.commentsSignature = signature; state.comments = data.comments; $('comments-count').textContent = String(data.comments.length);
    const nodes = data.comments.map((comment, index) => {
      const card = el('article', `comment${comment.parent_id ? ' reply' : ''}${comment.resolved ? ' resolved' : ''}`); card.id = `comment-${comment.id}`;
      const header = el('div', 'comment-head'); header.append(el('span', 'avatar', comment.author.slice(0, 1).toUpperCase()), el('span', 'comment-author', comment.author), el('span', 'comment-date', since(comment.created)));
      const controls = el('div', 'comment-controls');
      const button = (title, perform, className = '') => { const node = el('button', className, title); node.addEventListener('click', perform); controls.append(node); };
      if (comment.seconds !== null && state.media instanceof HTMLVideoElement) button(clock(comment.seconds), () => { state.media.currentTime = comment.seconds; state.media.play().catch(() => {}); }, 'time-chip');
      if (comment.x !== null) button(`Pin ${index + 1}`, () => { state.media.scrollIntoView({ block: 'center' }); });
      button('Reply', () => { state.reply = comment.id; $('reply-label').textContent = `Replying to ${comment.author}`; $('replying').hidden = false; $('comment-text').focus(); });
      if (state.owner) { button(comment.resolved ? 'Reopen' : 'Resolve', async () => { await api(`/api/comments/${comment.id}`, { method: 'PATCH', body: { resolved: !comment.resolved } }); loadComments(); }); button('Delete', async () => { if (!confirm('Remove this comment?')) return; await api(`/api/comments/${comment.id}`, { method: 'DELETE' }); loadComments(); }); }
      card.append(header, el('p', '', comment.text), controls); return card;
    });
    if (!nodes.length) nodes.push(el('p', 'hint', 'Start the conversation. Add a comment or pin a detail on the image.'));
    $('comments').replaceChildren(...nodes); renderPins(data.comments);
  } catch (error) { $('comment-error').textContent = error.message; }
}
function renderPins(comments) {
  $('media-stage').querySelectorAll('.marker').forEach((node) => node.remove());
  if (!(state.media instanceof HTMLImageElement)) return;
  const stage = $('media-stage').getBoundingClientRect(), image = state.media.getBoundingClientRect();
  comments.forEach((comment, index) => { if (comment.x === null || comment.resolved) return; const marker = el('button', 'marker', String(index + 1)); marker.setAttribute('aria-label', `Comment ${index + 1} by ${comment.author}`); marker.style.left = `${image.left - stage.left + comment.x * image.width}px`; marker.style.top = `${image.top - stage.top + comment.y * image.height}px`; marker.addEventListener('click', (event) => { event.stopPropagation(); $(`comment-${comment.id}`).scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' }); }); $('media-stage').append(marker); });
}
new ResizeObserver(() => { if (page === 'share') renderPins(state.comments || []); }).observe($('media-stage'));
async function postComment(event) {
  event.preventDefault(); const button = event.submitter; button.disabled = true; $('comment-error').textContent = '';
  const video = state.media instanceof HTMLVideoElement;
  try { await api(`/api/share/${token}/comments`, { method: 'POST', headers: { 'X-Share-CSRF': state.shareCSRF }, body: { author: $('guest-name').value || 'Guest', text: $('comment-text').value, parentId: state.reply, seconds: video && $('attach-time').checked ? state.media.currentTime : null, x: state.point?.x ?? null, y: state.point?.y ?? null } }); $('comment-text').value = ''; state.point = null; state.reply = null; $('replying').hidden = true; await loadComments(); }
  catch (error) { $('comment-error').textContent = error.message; }
  finally { button.disabled = false; }
}
function renderTranscript() {
  const item = state.item; if (!item) return;
  const search = $('transcript-search').value.toLocaleLowerCase();
  const cues = item.captions ? item.captions.split(/\n\s*\n/).map((block) => { const lines = block.split('\n'); const index = lines.findIndex((line) => line.includes(' --> ')); if (index < 0) return null; const parts = lines[index].split(' --> ')[0].split(':').map(Number); const seconds = parts.length === 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]; return { seconds, text: lines.slice(index + 1).join(' ') }; }).filter(Boolean) : [];
  if (cues.length) { $('transcript').replaceChildren(...cues.filter((cue) => !search || cue.text.toLocaleLowerCase().includes(search)).map((cue) => { const button = el('button', 'cue'); button.append(el('span', '', clock(cue.seconds)), document.createTextNode(cue.text)); button.addEventListener('click', () => { if (state.media instanceof HTMLVideoElement) { state.media.currentTime = cue.seconds; state.media.play().catch(() => {}); } }); return button; })); }
  else { $('transcript').textContent = item.transcript.split('\n').filter((line) => !search || line.toLocaleLowerCase().includes(search)).join('\n'); }
}

// Keep the skip link targeted at the visible page.
const skip = document.querySelector(".skip");
if (skip) skip.href = document.body.dataset.page === "share" ? "#share-main" : "#main";
