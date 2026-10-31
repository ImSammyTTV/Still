// The video editor: play a recording, choose the part to keep, export it as a video or a GIF.
//
// How trimming works, and its limits: a web engine has no way to cut a WebM or MP4 without re-encoding it,
// and the recorder writes keyframes too rarely to cut cleanly at the container level. So a trimmed export
// plays the kept part in an unseen player and records that with MediaRecorder, the same engine and bitrate
// as the original recording. That means it runs in real time and is a second generation of the picture.
// In Chromium, In and Out land within a frame or two. The canvas route for engines without captureStream is
// looser: on WebKit a 1.5 second clip came out about 0.6 seconds too long. It pauses while the window is hidden,
// because the page's timers slow down then. An untrimmed export skips all this and copies the file exactly.
// The trim points and background are saved beside the recording (its project.json), so the editor opens where it
// was left, beside the pointer's path and clicks that Still noted while recording. A background, zooms and click
// rings are drawn into every exported frame, so any of them means re-encoding.
const id = params.get('id');
const video = $('#video');
const BITRATE = 12_000_000; // Matches the recording HUD.
const THUMBNAILS = 9;
let item, source, duration = 0, trim = { start: 0, end: 0 }, job = null, project = {}, saveTimer = 0;
const NO_BG = { style: 'none', padding: 8, radius: 2, shadow: true };
let bg = { ...NO_BG };
const hasBg = () => bg.style !== 'none';
let zooms = [], selectedZoom = -1, showClicks = false, bgPicture = null;
const clicks = () => (Array.isArray(project.clicks) ? project.clicks : []);
const drawsClicks = () => showClicks && clicks().length > 0;
// Recordings made with Cursor effects on leave the pointer out of the picture; it's drawn here from the path.
let cursorFx = { show: true, size: 1, smooth: true, style: 'arrow' };
const separateCursor = () => project.cursor === 'separate';
const drawsCursor = () => separateCursor() && cursorFx.show && Array.isArray(project.pointer) && project.pointer.length > 0;
const needsCanvas = () => hasBg() || zooms.length > 0 || drawsClicks() || drawsCursor();

const message = (error) => (error && error.message) || String(error);

function showError(text, canOpenPlayer = false) {
  $('#errorText').textContent = text; $('#errorPlayer').hidden = !canOpenPlayer; $('#error').hidden = false;
}

// ---- Loading ------------------------------------------------------------------------------------

function loaded(player, url) {
  return new Promise((resolve, reject) => {
    player.onloadeddata = () => { player.onloadeddata = player.onerror = null; resolve(); };
    player.onerror = () => { player.onloadeddata = player.onerror = null; reject(new Error((player.error && player.error.message) || 'This system’s web engine can’t play this video.')); };
    player.crossOrigin = 'anonymous'; player.preload = 'auto'; player.src = url;
  });
}

// MediaRecorder's WebM files don't record their length, so the engine reports Infinity until it has
// looked at the end of the file. The library's stored length is the fallback.
async function realDuration(player, stored) {
  if (Number.isFinite(player.duration) && player.duration > 0) return player.duration;
  await new Promise((resolve) => {
    const done = () => { player.removeEventListener('durationchange', changed); clearTimeout(timer); resolve(); };
    const changed = () => { if (Number.isFinite(player.duration)) done(); };
    const timer = setTimeout(done, 5000);
    player.addEventListener('durationchange', changed);
    player.currentTime = 1e9;
  });
  const found = Number.isFinite(player.duration) ? player.duration : stored;
  player.currentTime = 0;
  return found > 0 ? found : stored;
}

function seek(player, time) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(reject, new Error('The video stopped responding while seeking.')), 15000);
    const finish = (settle, value) => { clearTimeout(timer); player.onseeked = player.onerror = null; settle(value); };
    player.onseeked = () => finish(resolve);
    player.onerror = () => finish(reject, new Error((player.error && player.error.message) || 'The video couldn’t be read.'));
    player.currentTime = time;
  });
}

// Exports read from a second, unseen player, so the one on screen is left alone. It's muted so nothing
// plays through the speakers; muting doesn't affect what captureStream records.
async function unseenPlayer() {
  const player = document.createElement('video');
  player.muted = true; player.playsInline = true;
  await loaded(player, source);
  return player;
}

async function fillThumbnails() {
  const strip = $('#strip'), player = await unseenPlayer();
  const canvases = Array.from({ length: THUMBNAILS }, () => el('canvas', { width: 180, height: Math.max(1, Math.round(180 * player.videoHeight / player.videoWidth)) }));
  strip.append(...canvases);
  for (const [i, canvas] of canvases.entries()) {
    await seek(player, Math.min(duration - 0.01, duration * i / THUMBNAILS));
    canvas.getContext('2d').drawImage(player, 0, 0, canvas.width, canvas.height);
  }
  player.removeAttribute('src'); player.load();
}

// ---- Trim bar -----------------------------------------------------------------------------------

function render() {
  const start = StillTrim.position(trim.start, duration) * 100, end = StillTrim.position(trim.end, duration) * 100;
  $('#shadeIn').style.width = `${start}%`; $('#shadeOut').style.width = `${100 - end}%`;
  $('#kept').style.left = `${start}%`; $('#kept').style.width = `${end - start}%`;
  $('#handleIn').style.left = `${start}%`; $('#handleOut').style.left = `${end}%`;
  for (const [handle, value] of [[$('#handleIn'), trim.start], [$('#handleOut'), trim.end]]) {
    handle.setAttribute('aria-valuemin', '0'); handle.setAttribute('aria-valuemax', duration.toFixed(1));
    handle.setAttribute('aria-valuenow', value.toFixed(1)); handle.setAttribute('aria-valuetext', StillTrim.clock(value));
  }
  $('#range').textContent = `${StillTrim.clock(trim.start)} — ${StillTrim.clock(trim.end)}  ·  ${StillTrim.clock(StillTrim.length(trim))}`;
  $('#reset').disabled = StillTrim.isFull(trim, duration);
  renderGifHint();
  saveProject();
}

// Saved a moment after the last change, so dragging a handle doesn't write the file on every step.
function saveProject() {
  if (!duration) return;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    project = { ...project, trim: StillTrim.isFull(trim, duration) ? null : { start: trim.start, end: trim.end }, bg: hasBg() ? bg : null, zooms, showClicks, cursorFx };
    still.invoke('video:project', project).catch(() => {}); // Losing the trim points is no reason to interrupt editing.
  }, 400);
}

function renderPlayhead() {
  $('#playhead').style.left = `${StillTrim.position(video.currentTime, duration) * 100}%`;
  $('#now').textContent = StillTrim.clock(video.currentTime);
  renderView();
}

function gifPlan() {
  const F = StillBackdrop.videoFrame(video.videoWidth, video.videoHeight, bg);
  return StillGIF.plan({ duration: StillTrim.length(trim), fps: Number($('#gifFps').value), width: Number($('#gifWidth').value), sourceWidth: F.w, sourceHeight: F.h });
}
function renderGifHint() {
  const plan = gifPlan();
  $('#gifHint').textContent = !plan.ok ? `Keep ${StillGIF.limits.maxSeconds} seconds or less for a GIF.`
    : `${plan.width} × ${plan.height}, ${plan.frames} frames${plan.lowered ? `, slowed to ${Math.round(plan.fps)} fps for length` : ''}`;
}

function jump(time) { video.currentTime = Math.min(trim.end, Math.max(trim.start, time)); renderPlayhead(); }
function setStart(time) { trim = StillTrim.setIn(trim, time, duration); render(); jump(trim.start); }
function setEnd(time) { trim = StillTrim.setOut(trim, time, duration); render(); jump(trim.end); }

// Handles move by how far you drag from where you grabbed them, so they don't jump to the pointer.
function dragHandle(handle, current, apply) {
  handle.addEventListener('pointerdown', (down) => {
    if (!duration) return;
    down.preventDefault(); down.stopPropagation(); handle.focus(); handle.setPointerCapture(down.pointerId);
    pause();
    const origin = current(), width = $('#bar').clientWidth;
    const move = (e) => apply(origin + (e.clientX - down.clientX) / width * duration);
    const up = () => { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', up); handle.removeEventListener('pointercancel', up); };
    handle.addEventListener('pointermove', move); handle.addEventListener('pointerup', up); handle.addEventListener('pointercancel', up);
  });
  handle.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault(); e.stopPropagation();
    apply(current() + (e.key === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? 1 : 0.1));
  });
}
dragHandle($('#handleIn'), () => trim.start, setStart);
dragHandle($('#handleOut'), () => trim.end, setEnd);

$('#bar').addEventListener('pointerdown', (down) => {
  if (!duration) return;
  const bar = $('#bar'), scrub = (e) => jump(StillTrim.timeAt(e.clientX - bar.getBoundingClientRect().left, bar.clientWidth, duration));
  bar.setPointerCapture(down.pointerId); scrub(down);
  const up = () => { bar.removeEventListener('pointermove', scrub); bar.removeEventListener('pointerup', up); bar.removeEventListener('pointercancel', up); };
  bar.addEventListener('pointermove', scrub); bar.addEventListener('pointerup', up); bar.addEventListener('pointercancel', up);
});

// ---- Background ---------------------------------------------------------------------------------

// The preview is laid out by hand so it shows exactly the frame an export will have.
function layoutPreview() {
  const stage = $('#stage'), vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return;
  const F = StillBackdrop.videoFrame(vw, vh, bg), s = Math.min(stage.clientWidth / F.w, stage.clientHeight / F.h);
  const frame = $('#frame');
  Object.assign(frame.style, { width: `${F.w * s}px`, height: `${F.h * s}px`, left: `${(stage.clientWidth - F.w * s) / 2}px`, top: `${(stage.clientHeight - F.h * s) / 2}px` });
  const [a, b] = StillBackdrop.GRADIENTS[bg.style] || [];
  frame.style.background = !hasBg() ? 'none' : bg.style === 'custom' ? `center / cover no-repeat url("${bg.custom}")` : `linear-gradient(135deg, ${a}, ${b})`;
  Object.assign($('#clip').style, { left: `${F.x * s}px`, top: `${F.y * s}px`, width: `${vw * s}px`, height: `${vh * s}px`, borderRadius: `${F.radius * s}px`,
    boxShadow: hasBg() && bg.shadow ? `0 ${Math.max(6, vw / 120) * s}px ${Math.max(20, vw / 30) * s}px rgba(0,0,0,.35)` : 'none' });
  const fx = $('#fx'); fx.width = Math.round(vw * s * devicePixelRatio); fx.height = Math.round(vh * s * devicePixelRatio);
  renderView();
}

// The zoom and click rings at the playhead, on the preview. The same StillZoom maths draws the exports.
function renderView() {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return;
  const t = video.currentTime, z = StillZoom.at(zooms, t), src = StillZoom.source(vw, vh, z);
  video.style.transform = z.scale === 1 ? '' : `translate(${-src.x / vw * z.scale * 100}%, ${-src.y / vh * z.scale * 100}%) scale(${z.scale})`;
  const fx = $('#fx'), ctx = fx.getContext('2d');
  ctx.clearRect(0, 0, fx.width, fx.height);
  drawOverlays(ctx, t, src, z.scale, fx.width / vw, 0, 0, vw, vh);
}

// What's drawn over the picture: click rings, then the pointer on top. Same arguments as drawRings.
function drawOverlays(ctx, t, src, scale, k, ox, oy, vw, vh) {
  if (drawsClicks()) drawRings(ctx, t, src, scale, k, ox, oy, vw, vh);
  if (!drawsCursor()) return;
  const p = StillCursor.at(project.pointer, t, cursorFx.smooth);
  if (!p) return;
  // As on the Mac: about a real pointer's size for the recording's width, times the chosen size and the zoom.
  const size = 24 * cursorFx.size * Math.max(0.7, vw / 1920) * scale * k;
  const x = ox + (p.x * vw - src.x) * scale * k, y = oy + (p.y * vh - src.y) * scale * k;
  // The Mac's Dot is 44 of its 64-point cursor box: about twice the arrow's height.
  if (cursorFx.style === 'dot') StillCursor.dot(ctx, x, y, size * 44 / 24); else StillCursor.draw(ctx, x, y, size);
}

// Rings where the pointer clicked, growing and fading. `k` turns video pixels into the target's pixels.
function drawRings(ctx, t, src, scale, k, ox, oy, vw, vh) {
  const unit = Math.max(1, vw / 900) * k;
  for (const ring of StillZoom.rings(clicks(), t)) {
    const x = ox + (ring.x * vw - src.x) * scale * k, y = oy + (ring.y * vh - src.y) * scale * k;
    ctx.beginPath(); ctx.arc(x, y, (10 + 22 * ring.progress) * unit, 0, Math.PI * 2);
    ctx.lineWidth = 3 * unit; ctx.strokeStyle = `rgba(255, 72, 94, ${1 - ring.progress})`; ctx.stroke();
  }
}
new ResizeObserver(layoutPreview).observe($('#stage'));
video.addEventListener('loadedmetadata', layoutPreview);

$('#swatches').append(el('button', { title: 'None', 'data-bg': 'none', html: icon('ban', 12), style: 'background:var(--bg-elevated)' }),
  ...Object.entries(StillBackdrop.GRADIENTS).map(([name, [a, b]]) => el('button', { title: name[0].toUpperCase() + name.slice(1), 'data-bg': name, style: `background:linear-gradient(135deg, ${a}, ${b})` })));
function renderBackground() {
  $$('#swatches button').forEach((b) => { b.classList.toggle('active', b.dataset.bg === bg.style); b.setAttribute('aria-pressed', String(b.dataset.bg === bg.style)); });
  $('#bgPadding').value = bg.padding; $('#bgRadius').value = bg.radius; $('#bgShadow').checked = bg.shadow;
  $$('#bgPadding, #bgRadius, #bgShadow').forEach((input) => { input.disabled = !hasBg(); });
  layoutPreview(); renderGifHint(); saveProject();
}
$('#swatches').addEventListener('click', (e) => { const b = e.target.closest('[data-bg]'); if (!b) return; bg = { ...bg, style: b.dataset.bg }; renderBackground(); });
$('#bgPadding').oninput = (e) => { bg = { ...bg, padding: Number(e.target.value) }; renderBackground(); };
$('#bgRadius').oninput = (e) => { bg = { ...bg, radius: Number(e.target.value) }; renderBackground(); };
$('#bgShadow').onchange = (e) => { bg = { ...bg, shadow: e.target.checked }; renderBackground(); };
// Your own picture, as in the image editor. It's kept in the project, so the background comes back with the recording.
async function loadPicture() {
  bgPicture = null;
  if (!bg.custom) return;
  const picture = new Image(); picture.src = bg.custom;
  await picture.decode().catch(() => {});
  if (picture.naturalWidth) bgPicture = picture;
}
$('#bgImage').onclick = async () => {
  const data = await still.invoke('editor:openImage').catch(() => null);
  if (!data) return;
  bg = { ...bg, style: 'custom', custom: data };
  await loadPicture(); renderBackground();
};
$('#background').onclick = () => {
  const panel = $('#backdrop'); panel.hidden = !panel.hidden;
  $('#background').setAttribute('aria-expanded', String(!panel.hidden));
  if (!panel.hidden && !hasBg()) bg = { ...bg, style: 'midnight' };
  renderBackground();
};

// One exported frame: the background, then the video's current picture inside it.
function drawFrame(ctx, player, F) {
  const t = player.currentTime, z = StillZoom.at(zooms, t), src = StillZoom.source(F.width, F.height, z);
  ctx.save();
  if (hasBg()) StillBackdrop.paint(ctx, F, { x: F.x, y: F.y, w: F.width, h: F.height, radius: F.radius }, bg, bgPicture);
  else { ctx.beginPath(); ctx.rect(F.x, F.y, F.width, F.height); ctx.clip(); }
  ctx.drawImage(player, src.x, src.y, src.w, src.h, F.x, F.y, F.width, F.height);
  drawOverlays(ctx, t, src, z.scale, 1, F.x, F.y, F.width, F.height);
  ctx.restore();
}

// ---- Zooms --------------------------------------------------------------------------------------

function renderZooms() {
  if (selectedZoom >= zooms.length) selectedZoom = -1;
  const lane = $('#lane'); lane.replaceChildren();
  zooms.forEach((z, i) => {
    const left = StillTrim.position(z.start, duration) * 100, width = (StillTrim.position(z.end, duration) * 100) - left;
    lane.append(el('button', { class: i === selectedZoom ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `Zoom ${StillTrim.clock(z.start)} to ${StillTrim.clock(z.end)}, ${z.scale}×`,
      'aria-pressed': String(i === selectedZoom), onclick: () => { selectedZoom = i === selectedZoom ? -1 : i; if (selectedZoom >= 0) jump(z.start + Math.min(0.5, (z.end - z.start) / 2)); renderZooms(); } }));
  });
  const z = zooms[selectedZoom];
  $('#zoomTools').hidden = !z;
  $('#clip').classList.toggle('aiming', !!z);
  if (z) $('#zoomScale').value = String(z.scale);
  $('#autoZoom').disabled = !duration || !clicks().length;
  $('#autoZoom').title = clicks().length ? 'A zoom wherever you clicked while recording' : 'Auto Zoom needs a recording made with Still 1.2.15 or later on Windows, or on Linux with X11';
  $('#clicksToggle').hidden = !clicks().length; $('#showClicks').checked = showClicks;
  $('#cursorRow').hidden = !separateCursor();
  $('#cursorShow').checked = cursorFx.show; $('#cursorSize').value = String(cursorFx.size); $('#cursorSmooth').checked = cursorFx.smooth;
  $('#cursorStyle').value = cursorFx.style === 'dot' ? 'dot' : 'arrow';
  $$('#cursorSize, #cursorSmooth, #cursorStyle').forEach((input) => { input.disabled = !cursorFx.show; });
  renderView(); saveProject();
}
const changeZoom = (patch) => { zooms = zooms.map((z, i) => (i === selectedZoom ? { ...z, ...patch } : z)).sort((a, b) => a.start - b.start); renderZooms(); };

$('#addZoom').onclick = () => {
  const time = video.currentTime;
  zooms = StillZoom.add(zooms, time, trim, project.pointer);
  selectedZoom = zooms.findIndex((z) => z.start <= time && z.end >= time); renderZooms();
};
$('#autoZoom').onclick = () => { zooms = StillZoom.auto(clicks(), trim); selectedZoom = -1; renderZooms(); toast(zooms.length ? `${zooms.length} zoom${zooms.length === 1 ? '' : 's'} added` : 'No clicks in the trimmed part'); };
$('#zoomRemove').onclick = () => { zooms = zooms.filter((_, i) => i !== selectedZoom); selectedZoom = -1; renderZooms(); };
$('#zoomScale').onchange = (e) => changeZoom({ scale: Number(e.target.value) });
$('#zoomIn').onclick = () => { const z = zooms[selectedZoom]; if (z && video.currentTime < z.end - 0.2) changeZoom({ start: video.currentTime }); };
$('#zoomOut').onclick = () => { const z = zooms[selectedZoom]; if (z && video.currentTime > z.start + 0.2) changeZoom({ end: video.currentTime }); };
$('#showClicks').onchange = (e) => { showClicks = e.target.checked; renderZooms(); };
$('#cursorShow').onchange = (e) => { cursorFx = { ...cursorFx, show: e.target.checked }; renderZooms(); };
$('#cursorSize').onchange = (e) => { cursorFx = { ...cursorFx, size: Number(e.target.value) }; renderZooms(); };
$('#cursorStyle').onchange = (e) => { cursorFx = { ...cursorFx, style: e.target.value }; renderZooms(); };
$('#cursorSmooth').onchange = (e) => { cursorFx = { ...cursorFx, smooth: e.target.checked }; renderZooms(); };
// With a zoom selected, a click on the video picks the point it zooms to, wherever the view is zoomed right now.
$('#clip').addEventListener('click', (e) => {
  if (selectedZoom < 0) return;
  e.stopPropagation();
  const r = $('#clip').getBoundingClientRect(), vw = video.videoWidth, vh = video.videoHeight;
  const src = StillZoom.source(vw, vh, StillZoom.at(zooms, video.currentTime));
  const x = (src.x + (e.clientX - r.left) / r.width * src.w) / vw, y = (src.y + (e.clientY - r.top) / r.height * src.h) / vh;
  changeZoom({ x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) });
}, true);

// ---- Playback -----------------------------------------------------------------------------------

function renderPlay() {
  const playing = !video.paused;
  $('#play').innerHTML = icon(playing ? 'pause' : 'play'); $('#play').title = playing ? 'Pause (Space)' : 'Play (Space)'; refreshIcons();
}
function pause() { if (!video.paused) video.pause(); }
function togglePlay() {
  if (!video.paused) return pause();
  if (video.currentTime >= trim.end - 0.05 || video.currentTime < trim.start) video.currentTime = trim.start;
  video.play().catch((error) => showError(`Couldn’t play the video: ${message(error)}`));
}
// Playback stops at Out. timeupdate covers a hidden window, where animation frames don't run.
function watchPlayback() {
  if (!duration) return; // Still measuring the file, which moves the playhead to the end and back.
  if (video.currentTime >= trim.end) { pause(); video.currentTime = trim.end; }
  renderPlayhead();
}
function animate() { if (video.paused) return; watchPlayback(); requestAnimationFrame(animate); }
video.addEventListener('play', () => { renderPlay(); animate(); });
video.addEventListener('pause', renderPlay);
video.addEventListener('timeupdate', watchPlayback);
video.addEventListener('seeked', renderPlayhead);
video.addEventListener('click', togglePlay);

$('#play').onclick = togglePlay;
$('#mute').onclick = () => {
  video.muted = !video.muted;
  $('#mute').innerHTML = icon(video.muted ? 'volume-x' : 'volume-2'); $('#mute').title = video.muted ? 'Unmute' : 'Mute'; refreshIcons();
};
$('#setIn').onclick = () => setStart(video.currentTime);
$('#setOut').onclick = () => setEnd(video.currentTime);
$('#reset').onclick = () => { trim = StillTrim.full(duration); render(); };
$('#gifWidth').onchange = $('#gifFps').onchange = renderGifHint;
$('#errorClose').onclick = () => { $('#error').hidden = true; };
$('#errorPlayer').onclick = () => still.send('library:play', id);
$('#cancel').onclick = () => { if (job) job.abort(); };

addEventListener('keydown', (e) => {
  if (job || e.metaKey || e.ctrlKey || e.altKey || e.target.closest('button, select, input')) return;
  if (e.key === ' ') { e.preventDefault(); togglePlay(); }
  else if (e.key === 'i' || e.key === 'I') $('#setIn').click();
  else if (e.key === 'o' || e.key === 'O') $('#setOut').click();
  else if ((e.key === 'z' || e.key === 'Z') && !$('#addZoom').disabled) $('#addZoom').click();
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedZoom >= 0) $('#zoomRemove').click();
});

// ---- Export -------------------------------------------------------------------------------------

function setProgress(fraction) {
  const percent = Math.round(Math.min(1, Math.max(0, fraction)) * 100);
  $('#progress').style.width = `${percent}%`; $('#percent').textContent = `${percent}%`; $('#progressBar').setAttribute('aria-valuenow', percent);
}
function setSheetNote(text) { $('#sheetNote').textContent = text || ''; $('#sheetNote').hidden = !text; }

// Runs one export behind the progress sheet. Nothing reaches the chosen file until the work is finished and
// Still has moved it into place, so cancelling or failing leaves that file, and the recording, untouched.
async function runExport(title, work) {
  pause();
  $('#error').hidden = true; $('#sheetTitle').textContent = title; setProgress(0); setSheetNote(''); $('#sheet').hidden = false; $('#cancel').disabled = false;
  job = { cancelled: false, onAbort: () => {}, abort() { this.cancelled = true; this.onAbort(); } };
  try {
    const file = await work(job);
    if (file) toast(`Exported ${file.split(/[\\/]/).pop()}`);
  } catch (error) {
    if (!job.cancelled) showError(`Couldn’t export: ${message(error)}`);
  } finally { job = null; $('#sheet').hidden = true; }
}

const save = (bytes) => { setProgress(1); $('#cancel').disabled = true; return still.raw('video_export_save', bytes, {}); };

// Where the frames come from. Chromium (WebView2) can record a media element directly, audio included.
// WebKitGTK can't, so there the picture goes through a canvas, as in the HUD, and the sound through Web Audio.
// A background always goes through the canvas, which draws it into each frame.
function captureSource(player) {
  if (player.captureStream && !needsCanvas()) return { stream: player.captureStream(), stop() {} };
  const F = StillBackdrop.videoFrame(player.videoWidth, player.videoHeight, bg);
  const canvas = el('canvas', { width: F.w, height: F.h }), ctx = canvas.getContext('2d', { alpha: false });
  const draw = () => drawFrame(ctx, player, F);
  draw();
  const timer = setInterval(draw, 1000 / 30);
  let audio = null, sound;
  if (player.captureStream) sound = player.captureStream().getAudioTracks();
  else {
    player.muted = false;
    audio = new AudioContext(); const mix = audio.createMediaStreamDestination();
    audio.createMediaElementSource(player).connect(mix);
    sound = mix.stream.getAudioTracks();
  }
  const tracks = [...canvas.captureStream(30).getVideoTracks(), ...sound];
  return { stream: new MediaStream(tracks), stop() { clearInterval(timer); if (audio) audio.close(); } };
}

async function recordClip(run, type) {
  const clip = { ...trim }, player = await unseenPlayer();
  await seek(player, clip.start);
  if (run.cancelled) return null;
  const capture = captureSource(player), chunks = [];
  const recorder = new MediaRecorder(capture.stream, { mimeType: type, videoBitsPerSecond: BITRATE });
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  let watcher;
  const finish = () => { clearInterval(watcher); if (recorder.state !== 'inactive') recorder.stop(); };
  const stopped = new Promise((resolve, reject) => {
    recorder.onstop = resolve;
    recorder.onerror = (e) => { reject(e.error || new Error('The web engine’s recorder stopped.')); finish(); };
    player.onerror = () => { reject(new Error((player.error && player.error.message) || 'The video couldn’t be read.')); finish(); };
  });
  run.onAbort = finish;
  const hidden = () => {
    if (recorder.state === 'inactive') return;
    if (document.hidden) { player.pause(); recorder.pause(); setSheetNote('Paused while this window is hidden.'); }
    else { recorder.resume(); player.play().catch(() => {}); setSheetNote(''); }
  };
  document.addEventListener('visibilitychange', hidden);
  try {
    // Playback starts first, so a slow start can't become a frozen opening frame.
    await player.play();
    if (run.cancelled) return null;
    recorder.start(1000);
    watcher = setInterval(() => {
      setProgress((player.currentTime - clip.start) / StillTrim.length(clip) * 0.98);
      if (player.ended || player.currentTime >= clip.end) finish();
    }, 10);
    await stopped;
  } finally {
    clearInterval(watcher); document.removeEventListener('visibilitychange', hidden);
    capture.stop(); player.removeAttribute('src'); player.load();
  }
  if (run.cancelled) return null;
  if (!chunks.length) throw new Error('The web engine’s recorder produced no video.');
  return new Uint8Array(await new Blob(chunks, { type }).arrayBuffer());
}

$('#exportVideo').onclick = () => {
  const ext = item.path.split('.').pop().toLowerCase();
  if (StillTrim.isFull(trim, duration) && !needsCanvas()) {
    return runExport('Exporting…', async () => {
      const target = await still.invoke('video:target', ext);
      return target && still.invoke('video:copy');
    });
  }
  const format = StillTrim.recorderType(ext, (type) => !!window.MediaRecorder && MediaRecorder.isTypeSupported(type));
  if (!format.type) return showError('Couldn’t export: this system’s web engine can’t record video, so a trimmed copy can’t be made here. GIF export still works.');
  runExport(needsCanvas() ? 'Exporting…' : 'Trimming…', async (run) => {
    const target = await still.invoke('video:target', format.ext);
    if (!target || run.cancelled) return null;
    const bytes = await recordClip(run, format.type);
    return bytes && save(bytes);
  });
};

$('#exportGif').onclick = () => {
  const plan = gifPlan();
  if (!plan.ok) return showError(plan.error);
  runExport('Making GIF…', async (run) => {
    const target = await still.invoke('video:target', 'gif');
    if (!target || run.cancelled) return null;
    const player = await unseenPlayer(), worker = new Worker('gif-worker.js');
    const canvas = el('canvas', { width: plan.width, height: plan.height }), ctx = canvas.getContext('2d', { alpha: false, willReadFrequently: true });
    ctx.imageSmoothingQuality = 'high';
    // One message, one reply: the page never gets ahead of the encoder, so frames can't pile up in memory.
    let failWorker = () => {};
    const ask = (data, transfer) => new Promise((resolve, reject) => {
      if (run.cancelled) return reject(new Error('Cancelled')); // The worker is gone; it would never reply.
      failWorker = reject;
      worker.onmessage = ({ data: reply }) => (reply.ok ? resolve(reply) : reject(new Error(reply.error)));
      worker.onerror = (e) => reject(new Error(e.message || 'The GIF encoder couldn’t start.'));
      worker.postMessage(data, transfer);
    });
    const F = StillBackdrop.videoFrame(player.videoWidth, player.videoHeight, bg);
    ctx.scale(plan.width / F.w, plan.height / F.h);
    const grab = async (time) => {
      await seek(player, time);
      drawFrame(ctx, player, F);
      return ctx.getImageData(0, 0, plan.width, plan.height).data;
    };
    run.onAbort = () => { worker.terminate(); failWorker(new Error('Cancelled')); };
    try {
      await ask({ type: 'start', width: plan.width, height: plan.height });
      const length = StillTrim.length(trim), samples = StillGIF.sampleTimes(trim.start, length);
      for (const [i, time] of samples.entries()) {
        const rgba = await grab(time);
        await ask({ type: 'sample', rgba }, [rgba.buffer]);
        setProgress((i + 1) / samples.length * 0.1);
      }
      for (let i = 0; i < plan.frames; i++) {
        const rgba = await grab(trim.start + i / plan.fps);
        await ask({ type: 'frame', rgba, delay: StillGIF.delayFor(i, plan.fps) }, [rgba.buffer]);
        setProgress(0.1 + (i + 1) / plan.frames * 0.88);
      }
      const { bytes } = await ask({ type: 'finish' });
      return await save(bytes);
    } finally { worker.terminate(); player.removeAttribute('src'); player.load(); }
  });
};

// ---- Start --------------------------------------------------------------------------------------

async function open() {
  item = await still.invoke('library:get', id);
  if (!item) return still.send('window:close');
  $('#title').textContent = item.title;
  source = `${still.fileUrl(item.path)}?t=${item.modified || item.created}`;
  try { await loaded(video, source); }
  catch {
    // Some engines won't stream from Still's file address. Reading the whole file works around that.
    const response = await fetch(source);
    if (!response.ok) throw new Error(`The file couldn’t be read (${response.status}).`);
    source = URL.createObjectURL(await response.blob());
    await loaded(video, source);
  }
  duration = await realDuration(video, item.duration || 0);
  if (!(duration > 0)) throw new Error('This video has no length.');
  project = item.project && typeof item.project === 'object' ? item.project : {};
  trim = StillTrim.restore(project.trim, duration);
  if (project.bg && (StillBackdrop.GRADIENTS[project.bg.style] || (project.bg.style === 'custom' && project.bg.custom))) bg = { ...NO_BG, ...project.bg };
  await loadPicture();
  zooms = (Array.isArray(project.zooms) ? project.zooms : []).filter((z) => z && z.end > z.start && z.scale >= 1);
  showClicks = !!project.showClicks;
  if (project.cursorFx && typeof project.cursorFx === 'object') cursorFx = { ...cursorFx, ...project.cursorFx };
  $('#status').hidden = true;
  $$('#play, #setIn, #setOut, #exportVideo, #exportGif, #background, #addZoom').forEach((button) => { button.disabled = false; });
  render(); renderPlayhead(); renderBackground(); renderZooms();
  if (hasBg()) { $('#backdrop').hidden = false; $('#background').setAttribute('aria-expanded', 'true'); }
  fillThumbnails().catch(() => {}); // The film strip is a nicety; trimming works without it.
}

applyTheme().then((prefs) => { if (prefs.platform !== 'darwin') addWindowControls(); return open(); })
  .catch((error) => { $('#status').hidden = true; showError(`Couldn’t open this recording: ${message(error)}`, true); });
refreshIcons();
still.on('library:changed', async () => { if (!(await still.invoke('library:get', id))) still.send('window:close'); });
