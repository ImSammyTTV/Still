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
const THUMBNAILS = 9;
let item, source, duration = 0, trim = { start: 0, end: 0 }, job = null, project = {}, saveTimer = 0;
const NO_BG = { style: 'none', padding: 8, radius: 2, shadow: true };
let bg = { ...NO_BG };
const hasBg = () => bg.style !== 'none';
let zooms = [], selectedZoom = -1, showClicks = false, bgPicture = null;
// The zooms picked on the lane: a click picks one, Ctrl- (⌘-) or Shift-click adds or drops one, so several can be
// removed together. `selectedZoom` is the one being edited when exactly one is picked.
let pickedZooms = new Set();
function pickZoom(i, adding) {
  if (!adding) pickedZooms = i >= 0 && !(pickedZooms.size === 1 && pickedZooms.has(i)) ? new Set([i]) : new Set();
  else if (pickedZooms.has(i)) pickedZooms.delete(i); else pickedZooms.add(i);
  selectedZoom = pickedZooms.size === 1 ? [...pickedZooms][0] : -1;
}
const clicks = () => (Array.isArray(project.clicks) ? project.clicks : []);
const drawsClicks = () => showClicks && clicks().length > 0;
// Recordings made with Cursor effects on leave the pointer out of the picture; it's drawn here from the path.
let cursorFx = { show: true, size: 1, smooth: true, style: 'arrow' };
const separateCursor = () => project.cursor === 'separate';
const drawsCursor = () => separateCursor() && cursorFx.show && Array.isArray(project.pointer) && project.pointer.length > 0;
// Text shown over the video for a stretch of it, and the one being edited.
let captions = [], selectedCaption = -1;
// Background music: { name, path, volume, duck, speech } — the file copied in beside the recording, its volume
// (0 to 1), whether it dips while someone speaks, and where the speech is (recording time, found once).
let music = null;
const musicPlayer = new Audio();
// Chapter markers, and the one being edited.
let chapters = [], selectedChapter = -1;
// Arrows, boxes and spotlights shown for a stretch, and the one being edited.
let callouts = [], selectedCallout = -1;
// Parts of the picture blurred for a stretch, and the one being edited.
let blurs = [], selectedBlur = -1;
// How the video opens and closes: 'none', 'fade' or 'rise'.
let opening = 'none', closing = 'none';
const ends = (t) => StillTransitions.at(t, trim, opening, closing);
const needsCanvas = () => hasBg() || zooms.length > 0 || drawsClicks() || drawsCursor() || captions.some((c) => c.text) || StillTransitions.active(opening, closing) || blurs.length > 0 || !!music || callouts.length > 0 || skims.length > 0;

const message = explain;

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

// Stretches cut out of the middle, in the recording's own time, and where a cut being marked began.
let cuts = [], cutStart = null;
// Stretches that play faster (2×, 4× or 8×) with a badge in the corner, and the one picked on its lane.
let skims = [], selectedSkim = -1;
function renderCuts() {
  const holder = $('#cuts'); holder.replaceChildren();
  cuts.forEach((c, i) => {
    const left = StillTrim.position(c.start, duration) * 100, width = StillTrim.position(c.end, duration) * 100 - left;
    const b = el('button', { class: 'cut', style: `left:${left}%;width:${width}%`, title: `Cut ${StillTrim.clock(c.start)} to ${StillTrim.clock(c.end)}: click to put it back`, 'aria-label': `Put back ${StillTrim.clock(c.start)} to ${StillTrim.clock(c.end)}` });
    b.addEventListener('pointerdown', (e) => e.stopPropagation());
    b.addEventListener('click', (e) => { e.stopPropagation(); cuts = StillTrim.removeCut(cuts, i); render(); });
    holder.append(b);
  });
  if (cutStart !== null) holder.append(el('div', { class: 'pending', style: `left:${StillTrim.position(cutStart, duration) * 100}%` }));
  $('#cut').innerHTML = `${icon('scissors')}${cutStart === null ? 'Cut' : 'End Cut'}`; refreshIcons();
  renderSkims();
}
function renderSkims() {
  if (selectedSkim >= skims.length) selectedSkim = -1;
  const lane = $('#skimLane'); lane.replaceChildren();
  skims.forEach((k, i) => {
    const left = StillTrim.position(k.start, duration) * 100, width = StillTrim.position(k.end, duration) * 100 - left;
    lane.append(el('button', { class: i === selectedSkim ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `Fast-forward ${k.rate}× ${StillTrim.clock(k.start)} to ${StillTrim.clock(k.end)}`, 'aria-pressed': String(i === selectedSkim),
      onclick: () => { selectedSkim = i === selectedSkim ? -1 : i; if (selectedSkim >= 0) jump(k.start); renderSkims(); } }));
  });
  const k = skims[selectedSkim];
  $('#skimTools').hidden = !k;
  if (k) $('#skimRate').value = String(k.rate);
}
const changeSkim = (patch) => {
  const k = skims[selectedSkim]; if (!k) return;
  const moved = { ...k, ...patch };
  skims = StillTrim.normalizeSkims([...skims.filter((_, i) => i !== selectedSkim), moved], trim);
  selectedSkim = skims.findIndex((x) => x.start === moved.start || (x.rate === moved.rate && x.end === moved.end)); render();
};
$('#addSkim').onclick = () => {
  const before = skims.length; skims = StillTrim.addSkim(skims, video.currentTime, trim, Number(exportChoice.skimRate) || 4);
  if (skims.length === before) return toast(StillTrim.skimAt(video.currentTime, skims) > 1 ? 'Already fast-forwarding here' : 'Too close to the end to fast-forward');
  selectedSkim = skims.findIndex((k) => k.start <= video.currentTime + 1e-6 && k.end > video.currentTime); render();
  toast('Fast-forward added. Move to where it should end and press End.');
};
$('#skimRate').onchange = (e) => { exportChoice.skimRate = Number(e.target.value); localStorage.setItem('stillVideoExport', JSON.stringify(exportChoice)); changeSkim({ rate: Number(e.target.value) }); };
$('#skimIn').onclick = () => { const k = skims[selectedSkim]; if (k && video.currentTime < k.end - StillTrim.MIN_SKIM) changeSkim({ start: video.currentTime }); };
$('#skimOut').onclick = () => { const k = skims[selectedSkim]; if (k && video.currentTime > k.start + StillTrim.MIN_SKIM) changeSkim({ end: video.currentTime }); };
$('#skimRemove').onclick = () => { skims = skims.filter((_, i) => i !== selectedSkim); selectedSkim = -1; render(); };
$('#cut').onclick = () => {
  if (cutStart === null) { cutStart = video.currentTime; toast('Move to where the cut ends, then press Cut again'); }
  else { const before = cuts.length; cuts = StillTrim.addCut(cuts, cutStart, video.currentTime, trim); cutStart = null; if (cuts.length === before && !cuts.some((c) => c.end - c.start > 0)) toast('Too short to cut'); }
  render();
};
// The recording's loudness in decibels for each 0.05 s, for Tighten Pauses and music ducking.
let levelsCache = null;
async function recordingLevels() {
  if (levelsCache) return levelsCache;
  const data = await (await fetch(video.currentSrc || source)).arrayBuffer();
  const context = new (window.AudioContext || window.webkitAudioContext)();
  let sound;
  try { sound = await context.decodeAudioData(data); } finally { context.close(); }
  const mono = new Float32Array(sound.length);
  for (let c = 0; c < sound.numberOfChannels; c++) { const channel = sound.getChannelData(c); for (let i = 0; i < mono.length; i++) mono[i] += channel[i] / sound.numberOfChannels; }
  return (levelsCache = StillTrim.levelsOf(mono, sound.sampleRate));
}
// Tighten Pauses: listens to the recording for silences longer than a second and cuts each down to a short beat.
$('#tighten').onclick = async () => {
  $('#tighten').disabled = true; toast('Listening for pauses…');
  try {
    const found = StillTrim.pauses(await recordingLevels(), 0.05, trim);
    const before = StillTrim.keptLength(trim, cuts);
    cuts = StillTrim.normalizeCuts([...cuts, ...found], trim); render();
    const saved = before - StillTrim.keptLength(trim, cuts);
    toast(found.length ? `Tightened ${found.length} pause${found.length === 1 ? '' : 's'}, ${saved.toFixed(1)} s shorter. Click a cut to put it back.` : 'No long pauses found');
  } catch (error) { const why = message(error); toast(/no sound/.test(why) ? why : `Couldn’t listen to this recording: ${why}`); }
  finally { $('#tighten').disabled = false; }
};
const isWhole = () => StillTrim.isFull(trim, duration) && !cuts.length && !skims.length;

function render() {
  cuts = StillTrim.normalizeCuts(cuts, trim); skims = StillTrim.normalizeSkims(skims, trim);
  renderCuts(); renderChapters(false);
  const start = StillTrim.position(trim.start, duration) * 100, end = StillTrim.position(trim.end, duration) * 100;
  $('#shadeIn').style.width = `${start}%`; $('#shadeOut').style.width = `${100 - end}%`;
  $('#kept').style.left = `${start}%`; $('#kept').style.width = `${end - start}%`;
  $('#handleIn').style.left = `${start}%`; $('#handleOut').style.left = `${end}%`;
  for (const [handle, value] of [[$('#handleIn'), trim.start], [$('#handleOut'), trim.end]]) {
    handle.setAttribute('aria-valuemin', '0'); handle.setAttribute('aria-valuemax', duration.toFixed(1));
    handle.setAttribute('aria-valuenow', value.toFixed(1)); handle.setAttribute('aria-valuetext', StillTrim.clock(value));
  }
  $('#range').textContent = `${StillTrim.clock(trim.start)} — ${StillTrim.clock(trim.end)}  ·  ${StillTrim.clock(StillTrim.keptLength(trim, cuts, skims))}${cuts.length ? ` · ${cuts.length} cut${cuts.length === 1 ? '' : 's'}` : ''}${skims.length ? ` · ${skims.length} fast` : ''}`;
  $('#reset').disabled = isWhole();
  renderGifHint();
  saveProject();
}

// Saved a moment after the last change, so dragging a handle doesn't write the file on every step.
function saveProject() {
  renderTabs();
  if (!duration) return;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    remember();
    project = { ...project, trim: StillTrim.isFull(trim, duration) ? null : { start: trim.start, end: trim.end }, cuts: cuts.length ? cuts : null, skims: skims.length ? skims : null, captions: captions.length ? captions : null, music, callouts: callouts.length ? callouts : null, chapters: chapters.length ? chapters : null, blurs: blurs.length ? blurs : null, opening: opening === 'none' ? null : opening, closing: closing === 'none' ? null : closing, bg: hasBg() ? bg : null, zooms, showClicks, cursorFx };
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
  return StillGIF.plan({ duration: StillTrim.keptLength(trim, cuts, skims), fps: Number($('#gifFps').value), width: Number($('#gifWidth').value), sourceWidth: F.w, sourceHeight: F.h });
}
function renderGifHint() {
  const plan = gifPlan();
  $('#gifGo').disabled = !plan.ok;
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
  syncMusic();
  const e = ends(t);
  const zoomed = z.scale === 1 ? '' : `translate(${-src.x / vw * z.scale * 100}%, ${-src.y / vh * z.scale * 100}%) scale(${z.scale})`;
  $('#clip').style.opacity = e.level < 1 ? String(e.level) : ''; $('#clip').style.transform = e.scale < 1 ? `scale(${e.scale})` : '';
  video.volume = Math.max(0, Math.min(1, e.level));
  video.style.transform = zoomed;
  const fx = $('#fx'), ctx = fx.getContext('2d');
  ctx.clearRect(0, 0, fx.width, fx.height);
  drawBlurs(ctx, video, t, src, z.scale, fx.width / vw, 0, 0, vw, vh);
  drawCallouts(ctx, t, src, z.scale, fx.width / vw, 0, 0, vw, vh);
  drawOverlays(ctx, t, src, z.scale, fx.width / vw, 0, 0, vw, vh);
  if (selectedBlur >= 0 && blurs[selectedBlur]) { const b = blurs[selectedBlur], k = fx.width / vw; ctx.save(); ctx.setLineDash([6, 4]); ctx.lineWidth = 2; ctx.strokeStyle = '#fff'; ctx.strokeRect((b.x * vw - src.x) * z.scale * k, (b.y * vh - src.y) * z.scale * k, b.w * vw * z.scale * k, b.h * vh * z.scale * k); ctx.restore(); }
}

// Blur boxes: each part of the picture shrunk to a few pixels and smoothed back up, which reads as a soft blur
// and works in every web engine. `media` is the video element being shown or exported.
const blurCanvas = document.createElement('canvas');
function drawBlurs(ctx, media, t, src, scale, k, ox, oy, vw, vh) {
  for (const b of StillBlurs.at(blurs, t)) {
    const sx = b.x * vw, sy = b.y * vh, sw = b.w * vw, sh = b.h * vh;
    const dx = ox + (sx - src.x) * scale * k, dy = oy + (sy - src.y) * scale * k, dw = sw * scale * k, dh = sh * scale * k;
    const small = Math.max(2, Math.round(Math.max(sw, sh) / 24));
    blurCanvas.width = Math.max(2, Math.round(small * sw / Math.max(sw, sh))); blurCanvas.height = Math.max(2, Math.round(small * sh / Math.max(sw, sh)));
    const b2 = blurCanvas.getContext('2d'); b2.imageSmoothingEnabled = true; b2.imageSmoothingQuality = 'high';
    b2.drawImage(media, sx, sy, sw, sh, 0, 0, blurCanvas.width, blurCanvas.height);
    ctx.save(); ctx.beginPath(); ctx.roundRect(dx, dy, dw, dh, Math.min(dw, dh) * 0.12); ctx.clip();
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high'; ctx.drawImage(blurCanvas, dx, dy, dw, dh);
    ctx.restore();
  }
}

// Callouts: arrows, boxes and spotlights, placed on the recording's picture so they follow it through zooms.
function drawCallouts(ctx, t, src, scale, k, ox, oy, vw, vh) {
  const px = (x, y) => ({ x: ox + (x * vw - src.x) * scale * k, y: oy + (y * vh - src.y) * scale * k });
  const unit = Math.max(1, Math.min(vw, vh) / 360) * k * Math.min(2, scale);
  for (const { callout: c, alpha } of StillCallouts.at(callouts, t)) {
    ctx.save(); ctx.globalAlpha = Math.max(0, alpha); ctx.strokeStyle = c.color; ctx.fillStyle = c.color; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 4 * unit;
    if (c.kind === 'arrow') {
      const tip = px(c.x, c.y), tail = px(c.x2, c.y2), [l, r] = StillCallouts.head(tail, tip, 16 * unit);
      ctx.lineWidth = 5 * unit; ctx.beginPath(); ctx.moveTo(tail.x, tail.y); ctx.lineTo(tip.x, tip.y); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(l.x, l.y); ctx.lineTo(tip.x, tip.y); ctx.lineTo(r.x, r.y); ctx.closePath(); ctx.fill();
    } else {
      const a = px(c.x, c.y), b = px(c.x + c.w, c.y + c.h);
      if (c.kind === 'spotlight') {
        ctx.shadowColor = 'transparent'; ctx.fillStyle = 'rgba(0,0,0,.6)';
        ctx.beginPath(); ctx.rect(ox, oy, vw * k, vh * k); ctx.roundRect(a.x, a.y, b.x - a.x, b.y - a.y, 10 * unit); ctx.fill('evenodd');
      } else { ctx.lineWidth = 4 * unit; ctx.beginPath(); ctx.roundRect(a.x, a.y, b.x - a.x, b.y - a.y, 8 * unit); ctx.stroke(); }
    }
    ctx.restore();
  }
}

// What's drawn over the picture: click rings, then the pointer on top. Same arguments as drawRings.
// While fast-forwarding the sound drops to a murmur, so it's there without chattering.
const voiceLevel = (t) => (StillTrim.skimAt(t, skims) > 1 ? 0.35 : 1);
// The fast-forward badge: two arrowheads and the rate, top right of the video, so viewers know time is skipping.
function drawSkimBadge(ctx, rate, ox, oy, w) {
  const unit = Math.max(1, w / 900), h = 30 * unit, pad = 10 * unit, label = `${rate}×`;
  ctx.save(); ctx.font = `600 ${15 * unit}px ${getComputedStyle(document.body).fontFamily}`;
  const width = 34 * unit + ctx.measureText(label).width + pad, x = ox + w - width - 14 * unit, y = oy + 14 * unit;
  ctx.fillStyle = 'rgba(0,0,0,.6)'; ctx.beginPath(); ctx.roundRect(x, y, width, h, h / 2); ctx.fill();
  ctx.fillStyle = '#fff';
  for (const dx of [0, 9 * unit]) { const ax = x + pad + dx; ctx.beginPath(); ctx.moveTo(ax, y + 9 * unit); ctx.lineTo(ax + 9 * unit, y + h / 2); ctx.lineTo(ax, y + h - 9 * unit); ctx.closePath(); ctx.fill(); }
  ctx.textBaseline = 'middle'; ctx.fillText(label, x + pad + 22 * unit, y + h / 2 + unit);
  ctx.restore();
}
function drawOverlays(ctx, t, src, scale, k, ox, oy, vw, vh) {
  if (drawsClicks()) drawRings(ctx, t, src, scale, k, ox, oy, vw, vh);
  const rate = StillTrim.skimAt(t, skims);
  if (rate > 1) drawSkimBadge(ctx, rate, ox, oy, vw * k);
  // Captions sit over the video area, steady through zooms.
  StillCaptions.draw(ctx, captions, t, ox, oy, vw * k, vh * k, getComputedStyle(document.body).fontFamily);
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
  const e = ends(t);
  ctx.save();
  if (e.level < 1) { ctx.fillStyle = '#000'; ctx.fillRect(0, 0, F.w, F.h); }
  if (hasBg()) StillBackdrop.paint(ctx, F, { x: F.x, y: F.y, w: F.width, h: F.height, radius: F.radius }, bg, bgPicture);
  else { ctx.beginPath(); ctx.rect(F.x, F.y, F.width, F.height); ctx.clip(); }
  // The opening and closing: the picture fades over the background (or black), and rises from slightly smaller.
  if (e.scale < 1) { const cx = F.x + F.width / 2, cy = F.y + F.height / 2; ctx.translate(cx, cy); ctx.scale(e.scale, e.scale); ctx.translate(-cx, -cy); }
  ctx.globalAlpha = e.level;
  ctx.drawImage(player, src.x, src.y, src.w, src.h, F.x, F.y, F.width, F.height);
  drawBlurs(ctx, player, t, src, z.scale, 1, F.x, F.y, F.width, F.height);
  drawCallouts(ctx, t, src, z.scale, 1, F.x, F.y, F.width, F.height);
  drawOverlays(ctx, t, src, z.scale, 1, F.x, F.y, F.width, F.height);
  ctx.restore();
}

// ---- Music --------------------------------------------------------------------------------------

// The music's volume at `t` (recording time): its own volume, dipped under speech, faded with the opening and closing.
const musicLevel = (t) => !music ? 0 : music.volume * (music.duck ? StillTrim.duck(t, music.speech) : 1) * ends(t).level;
function renderMusic(save = true) {
  $('#musicName').textContent = music ? music.name : 'None';
  $('#musicTools').hidden = !music;
  if (music) { $('#musicVolume').value = String(Math.round(music.volume * 100)); $('#musicDuck').checked = !!music.duck; }
  if (save) saveProject();
}
async function loadMusic() {
  if (!music) { musicPlayer.removeAttribute('src'); musicPlayer.load(); return; }
  musicPlayer.src = still.fileUrl(music.path); musicPlayer.loop = true; musicPlayer.preload = 'auto';
}
$('#chooseMusic').onclick = async () => {
  let picked;
  try { picked = await still.invoke('video:music'); } catch (error) { return toast(message(error)); }
  if (!picked) return;
  music = { name: picked.name, path: picked.path, volume: music ? music.volume : 0.3, duck: music ? music.duck : true, speech: [] };
  await loadMusic(); renderMusic();
  try { music.speech = StillTrim.speech(await recordingLevels(), 0.05); saveProject(); toast(music.speech.length ? 'Music added. It dips whenever someone speaks.' : 'Music added'); }
  catch { toast('Music added. Couldn’t listen for speech, so it stays at one volume.'); }
};
$('#musicVolume').oninput = (e) => { if (music) { music = { ...music, volume: Number(e.target.value) / 100 }; renderView(); renderMusic(); } };
$('#musicDuck').onchange = (e) => { if (music) { music = { ...music, duck: e.target.checked }; renderMusic(); } };
$('#musicRemove').onclick = () => { music = null; loadMusic(); renderMusic(); };
// The preview plays the music along with the video, from the finished video's moment, looping when it's short.
function syncMusic() {
  if (!music || !musicPlayer.src) return;
  if (video.paused) { if (!musicPlayer.paused) musicPlayer.pause(); return; }
  const at = StillTrim.outputAt(video.currentTime, StillTrim.kept(trim, cuts, skims)), d = musicPlayer.duration;
  const want = Number.isFinite(d) && d > 0 ? at % d : at;
  if (Math.abs(musicPlayer.currentTime - want) > 0.3) musicPlayer.currentTime = want;
  musicPlayer.volume = Math.max(0, Math.min(1, musicLevel(video.currentTime)));
  if (musicPlayer.paused) musicPlayer.play().catch(() => {});
}
video.addEventListener('pause', syncMusic);

// ---- Chapters -----------------------------------------------------------------------------------

function renderChapters(save = true) {
  if (selectedChapter >= chapters.length) selectedChapter = -1;
  const holder = $('#chapters'); holder.replaceChildren();
  chapters.forEach((c, i) => {
    const b = el('button', { class: i === selectedChapter ? 'selected' : '', style: `left:${StillTrim.position(c.time, duration) * 100}%`, title: `${c.title} · ${StillTrim.clock(c.time)}`, 'aria-label': `Chapter ${c.title}` });
    b.addEventListener('pointerdown', (e) => e.stopPropagation());
    b.addEventListener('click', (e) => { e.stopPropagation(); selectedChapter = i === selectedChapter ? -1 : i; if (selectedChapter >= 0) jump(c.time); renderChapters(); });
    holder.append(b);
  });
  const c = chapters[selectedChapter];
  $('#chapterTools').hidden = !c;
  if (c && document.activeElement !== $('#chapterTitle')) $('#chapterTitle').value = c.title;
  $('#copyChapters').disabled = !chapters.length;
  if (save) saveProject();
}
$('#addChapter').onclick = () => {
  const before = new Set(chapters); chapters = StillChapters.add(chapters, video.currentTime);
  selectedChapter = chapters.findIndex((c) => !before.has(c)); renderChapters(); $('#chapterTitle').focus(); $('#chapterTitle').select();
};
$('#chapterTitle').addEventListener('input', (e) => { chapters = chapters.map((c, i) => (i === selectedChapter ? { ...c, title: e.target.value } : c)); renderChapters(); });
$('#chapterTitle').addEventListener('keydown', (e) => { if (e.key === 'Enter') e.target.blur(); });
$('#chapterHere').onclick = () => { const moved = { ...chapters[selectedChapter], time: video.currentTime }; chapters = chapters.map((c, i) => (i === selectedChapter ? moved : c)).sort((a, b) => a.time - b.time); selectedChapter = chapters.indexOf(moved); renderChapters(); };
$('#chapterRemove').onclick = () => { chapters = chapters.filter((_, i) => i !== selectedChapter); selectedChapter = -1; renderChapters(); };
// How much the picture changes through the kept part: a tiny greyscale copy every `step` seconds (half a second,
// or longer on long recordings) and the difference between each and the next. Progress fills up to `share`.
async function scanChanges(run, player, share) {
  const span = trim.end - trim.start, step = Math.max(0.5, span / 400), total = Math.max(1, Math.floor(span / step));
  const small = el('canvas', { width: 32, height: 18 }), sctx = small.getContext('2d', { willReadFrequently: true });
  const grey = () => {
    sctx.drawImage(player, 0, 0, 32, 18);
    const d = sctx.getImageData(0, 0, 32, 18).data, g = new Array(576);
    for (let i = 0; i < 576; i++) g[i] = d[i * 4] * 0.299 + d[i * 4 + 1] * 0.587 + d[i * 4 + 2] * 0.114;
    return g;
  };
  const changes = []; let last = null;
  for (let i = 0; i <= total; i++) {
    if (run.cancelled) return null;
    await seek(player, Math.min(trim.end, trim.start + i * step));
    const g = grey(); if (last) changes.push(StillChapters.difference(last, g)); last = g;
    setProgress(i / total * share);
  }
  return { changes, step, grey };
}
// Speed Up Waits: stretches where the picture barely moves and nobody speaks (a progress bar, an install, a page
// loading) become 4× fast-forwards, leaving half a second at each end.
$('#speedWaits').onclick = () => runExport('Looking for waits…', async (run) => {
  try {
    let speech = [];
    try { speech = StillTrim.speech(await recordingLevels(), 0.05); } catch { /* No sound: every still stretch counts. */ }
    const player = await unseenPlayer();
    try {
      const scan = await scanChanges(run, player, 1);
      if (!scan) return null;
      const found = StillTrim.waits(scan.changes, scan.step, speech, { start: trim.start, rate: Number(exportChoice.skimRate) || 4 })
        .filter((w) => !cuts.some((c) => c.start < w.end && c.end > w.start));
      const before = StillTrim.keptLength(trim, cuts, skims);
      skims = StillTrim.normalizeSkims([...skims, ...found], trim); selectedSkim = -1; render(); showTab('trim');
      const saved = before - StillTrim.keptLength(trim, cuts, skims);
      toast(found.length && saved > 0.05 ? `Sped up ${found.length} wait${found.length === 1 ? '' : 's'}, ${saved.toFixed(1)} s shorter. Click one on its lane to change it.` : 'No long waits found');
    } finally { player.removeAttribute('src'); player.load(); }
  } catch (error) { if (!run.cancelled) toast(`Couldn’t look for waits: ${message(error)}`); }
  return null;
});
// Find Chapters: watches the kept part for big changes in the picture (another app, a new page, a new slide) and
// marks a chapter at each, named from the largest text on screen just after the change.
$('#findChapters').onclick = () => runExport('Finding chapters…', async (run) => {
  try {
    const player = await unseenPlayer();
    try {
      const scan = await scanChanges(run, player, 0.7);
      if (!scan) return null;
      const { changes, step, grey } = scan;
      const rough = StillChapters.scenes(changes, step, { start: trim.start })
        .filter((t) => !cuts.some((c) => t >= c.start && t < c.end) && !chapters.some((c) => Math.abs(c.time - t) < 3)).slice(0, 24);
      // Each change is somewhere in the step before; halving it five times finds the moment to a few hundredths.
      const times = [];
      for (const t of rough) {
        if (run.cancelled) return null;
        let lo = t - step, hi = t;
        await seek(player, lo); const before = grey(); await seek(player, hi); const after = grey();
        for (let k = 0; k < 5; k++) {
          const mid = (lo + hi) / 2; await seek(player, mid); const g = grey();
          if (StillChapters.difference(g, after) < StillChapters.difference(g, before)) hi = mid; else lo = mid;
        }
        times.push(hi);
      }
      if (!times.length) { toast('No clear changes of scene found'); return null; }
      const big = el('canvas', { width: player.videoWidth, height: player.videoHeight }), bctx = big.getContext('2d');
      const found = []; let named = 0;
      for (const [n, t] of times.entries()) {
        if (run.cancelled) return null;
        // A moment after the change, once the new screen has finished drawing.
        await seek(player, Math.min(trim.end - 0.05, t + 0.4)); bctx.drawImage(player, 0, 0);
        let title = '';
        try { title = StillChapters.titleFrom(await StillOCR.lines(big.toDataURL('image/png'))); } catch { /* Unnamed is fine. */ }
        if (title) named++;
        found.push({ time: t, title: title || `Chapter ${chapters.length + n + 1}` });
        setProgress(0.7 + (n + 1) / times.length * 0.3);
      }
      chapters = [...chapters, ...found].sort((a, b) => a.time - b.time); selectedChapter = -1; renderChapters(); showTab('chapters');
      toast(`Found ${found.length} chapter${found.length === 1 ? '' : 's'}${named ? `, ${named === found.length ? 'all' : named} named from the screen` : ''}. Click a flag to rename or move one.`);
    } finally { player.removeAttribute('src'); player.load(); }
  } catch (error) { if (!run.cancelled) toast(`Couldn’t look for chapters: ${message(error)}`); }
  return null;
});
$('#copyChapters').onclick = async () => {
  const speed = Number(exportChoice.speed) || 1, text = StillChapters.list(chapters, trim, cuts, speed, skims);
  if (!text) return toast('No chapters in the part you keep');
  try { await navigator.clipboard.writeText(text); toast(`Chapters copied${speed > 1 ? ` (timed for ${speed}× export)` : ''}`); }
  catch { toast('Couldn’t copy the chapters'); }
};

// ---- Callouts -----------------------------------------------------------------------------------

function renderCallouts(save = true) {
  if (selectedCallout >= callouts.length) selectedCallout = -1;
  const lane = $('#calloutLane'); lane.replaceChildren();
  callouts.forEach((c, i) => {
    const left = StillTrim.position(c.start, duration) * 100, width = StillTrim.position(c.end, duration) * 100 - left;
    lane.append(el('button', { class: i === selectedCallout ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `${c.kind[0].toUpperCase()}${c.kind.slice(1)} ${StillTrim.clock(c.start)} to ${StillTrim.clock(c.end)}`, 'aria-pressed': String(i === selectedCallout),
      onclick: () => { pickCallout(i === selectedCallout ? -1 : i); if (selectedCallout >= 0) jump(c.start + Math.min(0.5, (c.end - c.start) / 2)); } }));
  });
  const c = callouts[selectedCallout];
  $('#calloutTools').hidden = !c;
  if (c) { $('#calloutColor').value = c.color; $('#calloutHint').textContent = c.kind === 'arrow' ? 'Drag on the video from the tail to the tip.' : 'Drag on the video to place it.'; }
  $('#pointClicks').hidden = !clicks().length;
  $('#clip').classList.toggle('placing', selectedBlur >= 0 || selectedCallout >= 0);
  renderView(); if (save) saveProject();
}
function pickCallout(i) { selectedCallout = i; if (i >= 0) { selectedBlur = -1; pickZoom(-1, false); renderZooms(); renderBlurs(); } renderCallouts(); }
const changeCallout = (patch) => { let changed = null; callouts = callouts.map((c, i) => (i === selectedCallout ? (changed = { ...c, ...patch }) : c)).sort((a, b) => a.start - b.start); if (changed) selectedCallout = callouts.indexOf(changed); renderCallouts(); };
for (const [button, kind] of [['#addArrow', 'arrow'], ['#addBox', 'box'], ['#addSpot', 'spotlight']]) {
  $(button).onclick = () => { const before = new Set(callouts); callouts = StillCallouts.add(callouts, kind, video.currentTime, trim); pickCallout(callouts.findIndex((c) => !before.has(c))); toast(kind === 'arrow' ? 'Drag on the video from where the arrow starts to what it points at' : 'Drag on the video to place it'); };
}
$('#pointClicks').onclick = () => {
  const found = StillCallouts.fromClicks(clicks(), trim);
  if (!found.length) return toast('No clicks in the part you keep');
  callouts = [...callouts, ...found].sort((a, b) => a.start - b.start); pickCallout(-1);
  toast(`${found.length} arrow${found.length === 1 ? '' : 's'} added, one for each click`);
};
$('#calloutColor').onchange = (e) => changeCallout({ color: e.target.value });
$('#calloutIn').onclick = () => { const c = callouts[selectedCallout]; if (c && video.currentTime < c.end - 0.2) changeCallout({ start: video.currentTime }); };
$('#calloutOut').onclick = () => { const c = callouts[selectedCallout]; if (c && video.currentTime > c.start + 0.2) changeCallout({ end: video.currentTime }); };
$('#calloutRemove').onclick = () => { callouts = callouts.filter((_, i) => i !== selectedCallout); selectedCallout = -1; renderCallouts(); };
// With a callout picked, dragging on the video places it: an arrow from its tail to its tip, a box or spotlight
// across the drag.
$('#clip').addEventListener('pointerdown', (down) => {
  if (selectedCallout < 0 || down.button !== 0) return;
  down.preventDefault(); down.stopPropagation();
  const r = $('#clip').getBoundingClientRect(), vw = video.videoWidth, vh = video.videoHeight;
  const src = StillZoom.source(vw, vh, StillZoom.at(zooms, video.currentTime));
  const share = (e) => ({ x: Math.min(1, Math.max(0, (src.x + (e.clientX - r.left) / r.width * src.w) / vw)), y: Math.min(1, Math.max(0, (src.y + (e.clientY - r.top) / r.height * src.h) / vh)) });
  const from = share(down), clip = $('#clip'); clip.setPointerCapture(down.pointerId);
  const move = (e) => {
    const to = share(e), c = callouts[selectedCallout];
    callouts[selectedCallout] = c.kind === 'arrow' ? { ...c, x2: from.x, y2: from.y, x: to.x, y: to.y } : { ...c, ...StillBlurs.fromDrag(from, to) };
    renderView();
  };
  const up = (e) => { move(e); clip.removeEventListener('pointermove', move); clip.removeEventListener('pointerup', up); renderCallouts(); };
  clip.addEventListener('pointermove', move); clip.addEventListener('pointerup', up);
}, true);

// ---- Blur ---------------------------------------------------------------------------------------

function renderBlurs() {
  if (selectedBlur >= blurs.length) selectedBlur = -1;
  const lane = $('#blurLane'); lane.replaceChildren();
  blurs.forEach((b, i) => {
    const left = StillTrim.position(b.start, duration) * 100, width = StillTrim.position(b.end, duration) * 100 - left;
    lane.append(el('button', { class: i === selectedBlur ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `Blur ${StillTrim.clock(b.start)} to ${StillTrim.clock(b.end)}`, 'aria-pressed': String(i === selectedBlur),
      onclick: () => { selectedBlur = i === selectedBlur ? -1 : i; if (selectedBlur >= 0) { selectedCallout = -1; renderCallouts(false); pickZoom(-1, false); jump(b.start + Math.min(0.5, (b.end - b.start) / 2)); renderZooms(); } renderBlurs(); } }));
  });
  $('#blurTools').hidden = selectedBlur < 0;
  $('#clip').classList.toggle('placing', selectedBlur >= 0 || selectedCallout >= 0);
  renderView(); saveProject();
}
const changeBlur = (patch) => { let changed = null; blurs = blurs.map((b, i) => (i === selectedBlur ? (changed = { ...b, ...patch }) : b)).sort((a, b) => a.start - b.start); if (changed) selectedBlur = blurs.indexOf(changed); renderBlurs(); };
$('#addBlur').onclick = () => { const before = new Set(blurs); blurs = StillBlurs.add(blurs, video.currentTime, trim); selectedBlur = blurs.findIndex((b) => !before.has(b)); pickZoom(-1, false); renderZooms(); renderBlurs(); toast('Drag on the video to place the blur'); };
$('#blurIn').onclick = () => { const b = blurs[selectedBlur]; if (b && video.currentTime < b.end - 0.2) changeBlur({ start: video.currentTime }); };
$('#blurOut').onclick = () => { const b = blurs[selectedBlur]; if (b && video.currentTime > b.start + 0.2) changeBlur({ end: video.currentTime }); };
$('#blurRemove').onclick = () => { blurs = blurs.filter((_, i) => i !== selectedBlur); selectedBlur = -1; renderBlurs(); };
// With a blur picked, dragging on the video draws its box (as shares of the video, through any zoom).
$('#clip').addEventListener('pointerdown', (down) => {
  if (selectedBlur < 0 || down.button !== 0) return;
  down.preventDefault(); down.stopPropagation();
  const r = $('#clip').getBoundingClientRect(), vw = video.videoWidth, vh = video.videoHeight;
  const src = StillZoom.source(vw, vh, StillZoom.at(zooms, video.currentTime));
  const share = (e) => ({ x: (src.x + (e.clientX - r.left) / r.width * src.w) / vw, y: (src.y + (e.clientY - r.top) / r.height * src.h) / vh });
  const from = share(down), clip = $('#clip'); clip.setPointerCapture(down.pointerId);
  const move = (e) => { blurs[selectedBlur] = { ...blurs[selectedBlur], ...StillBlurs.fromDrag(from, share(e)) }; renderView(); };
  const up = (e) => { move(e); clip.removeEventListener('pointermove', move); clip.removeEventListener('pointerup', up); renderBlurs(); };
  clip.addEventListener('pointermove', move); clip.addEventListener('pointerup', up);
}, true);
// Find Private Info: reads the frame on screen and blurs each email address, card number, key, IP address and
// phone number it finds, for three seconds from here.
$('#findPrivate').onclick = async () => {
  $('#findPrivate').disabled = true; toast('Reading this frame…');
  try {
    const c = document.createElement('canvas'); c.width = video.videoWidth; c.height = video.videoHeight;
    c.getContext('2d').drawImage(video, 0, 0);
    const found = StillPrivate.boxes(await StillOCR.lines(c.toDataURL('image/png')));
    if (!found.length) return toast('No private details found in this frame');
    const time = video.currentTime;
    for (const box of found) blurs = StillBlurs.add(blurs, time, trim, StillBlurs.fromPixels(box, c.width, c.height));
    selectedBlur = -1; renderBlurs();
    toast(`Blurred ${found.length} private detail${found.length === 1 ? '' : 's'} for 3 seconds. Pick one on the lane to adjust it.`);
  } catch (error) { toast(`Couldn’t read this frame: ${message(error)}`); }
  finally { $('#findPrivate').disabled = false; }
};

// ---- Text ---------------------------------------------------------------------------------------

function renderCaptions() {
  if (selectedCaption >= captions.length) selectedCaption = -1;
  const lane = $('#captionLane'); lane.replaceChildren();
  captions.forEach((c, i) => {
    const left = StillTrim.position(c.start, duration) * 100, width = StillTrim.position(c.end, duration) * 100 - left;
    lane.append(el('button', { class: i === selectedCaption ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `“${c.text}” ${StillTrim.clock(c.start)} to ${StillTrim.clock(c.end)}`, 'aria-pressed': String(i === selectedCaption),
      onclick: () => { selectedCaption = i === selectedCaption ? -1 : i; if (selectedCaption >= 0) jump(c.start + Math.min(0.5, (c.end - c.start) / 2)); renderCaptions(); } }));
  });
  const c = captions[selectedCaption];
  $('#captionTools').hidden = !c;
  if (c) { if (document.activeElement !== $('#captionText')) $('#captionText').value = c.text; $('#captionPlace').value = c.position; $('#captionSize').value = c.size; }
  renderView(); saveProject();
}
const changeCaption = (patch) => { let changed = null; captions = captions.map((c, i) => (i === selectedCaption ? (changed = { ...c, ...patch }) : c)).sort((a, b) => a.start - b.start); if (changed) selectedCaption = captions.indexOf(changed); renderCaptions(); };
$('#addCaption').onclick = () => {
  captions = StillCaptions.add(captions, video.currentTime, trim);
  selectedCaption = captions.findIndex((c) => c.start <= video.currentTime + 0.01 && c.end >= video.currentTime && c.text === 'Your text');
  renderCaptions(); $('#captionText').focus(); $('#captionText').select();
};
$('#opening').onchange = (e) => { opening = e.target.value; renderView(); saveProject(); };
$('#closing').onchange = (e) => { closing = e.target.value; renderView(); saveProject(); };
$('#captionText').addEventListener('input', (e) => changeCaption({ text: e.target.value }));
$('#captionPlace').onchange = (e) => changeCaption({ position: e.target.value });
$('#captionSize').onchange = (e) => changeCaption({ size: e.target.value });
$('#captionIn').onclick = () => { const c = captions[selectedCaption]; if (c && video.currentTime < c.end - 0.2) changeCaption({ start: video.currentTime }); };
$('#captionOut').onclick = () => { const c = captions[selectedCaption]; if (c && video.currentTime > c.start + 0.2) changeCaption({ end: video.currentTime }); };
$('#captionRemove').onclick = () => { captions = captions.filter((_, i) => i !== selectedCaption); selectedCaption = -1; renderCaptions(); };

// ---- Zooms --------------------------------------------------------------------------------------

function renderZooms() {
  pickedZooms = new Set([...pickedZooms].filter((i) => i < zooms.length));
  selectedZoom = pickedZooms.size === 1 ? [...pickedZooms][0] : -1;
  const lane = $('#lane'); lane.replaceChildren();
  zooms.forEach((z, i) => {
    const left = StillTrim.position(z.start, duration) * 100, width = (StillTrim.position(z.end, duration) * 100) - left;
    lane.append(el('button', { class: pickedZooms.has(i) ? 'selected' : '', style: `left:${left}%;width:${width}%`, title: `Zoom ${StillTrim.clock(z.start)} to ${StillTrim.clock(z.end)}, ${z.scale}×. Ctrl-click to pick several.`,
      'aria-pressed': String(pickedZooms.has(i)), onclick: (e) => { pickZoom(i, e.ctrlKey || e.metaKey || e.shiftKey); if (selectedZoom >= 0) jump(z.start + Math.min(0.5, (z.end - z.start) / 2)); renderZooms(); } }));
  });
  const z = zooms[selectedZoom], several = pickedZooms.size > 1;
  $('#zoomTools').hidden = !pickedZooms.size;
  $$('#zoomTools .one-zoom, #zoomHint').forEach((part) => { part.hidden = several; });
  $('#zoomRemove').innerHTML = `${icon('trash-2')}${several ? `Remove ${pickedZooms.size} Zooms` : 'Remove'}`; refreshIcons();
  $('#zoomRemove').title = several ? 'Remove the picked zooms (Delete)' : 'Remove this zoom (Delete)';
  $('#clip').classList.toggle('aiming', !!z);
  if (z) $('#zoomScale').value = String(z.scale);
  $('#autoZoom').disabled = !duration || !clicks().length;
  $('#autoZoom').title = clicks().length ? 'A zoom wherever you clicked while recording' : 'Auto Zoom needs a recording made with Still 1.2.15 or later on Windows, or on Linux with X11';
  $('#clicksToggle').hidden = !clicks().length; $('#showClicks').checked = showClicks;
  $('#tabCursor').hidden = !separateCursor(); if (tab === 'cursor' && !separateCursor()) showTab('trim');
  $('#cursorShow').checked = cursorFx.show; $('#cursorSize').value = String(cursorFx.size); $('#cursorSmooth').checked = cursorFx.smooth;
  $('#cursorStyle').value = cursorFx.style === 'dot' ? 'dot' : 'arrow';
  $$('#cursorSize, #cursorSmooth, #cursorStyle').forEach((input) => { input.disabled = !cursorFx.show; });
  renderView(); saveProject();
}
const changeZoom = (patch) => { let changed = null; zooms = zooms.map((z, i) => (i === selectedZoom ? (changed = { ...z, ...patch }) : z)).sort((a, b) => a.start - b.start); if (changed) pickZoom(zooms.indexOf(changed), false); renderZooms(); };

$('#addZoom').onclick = () => {
  const time = video.currentTime;
  zooms = StillZoom.add(zooms, time, trim, project.pointer);
  pickZoom(zooms.findIndex((z) => z.start <= time && z.end >= time), false); renderZooms();
};
$('#autoZoom').onclick = () => { zooms = StillZoom.auto(clicks(), trim); pickZoom(-1, false); renderZooms(); toast(zooms.length ? `${zooms.length} zoom${zooms.length === 1 ? '' : 's'} added` : 'No clicks in the trimmed part'); };
$('#zoomRemove').onclick = () => { const gone = pickedZooms.size; zooms = zooms.filter((_, i) => !pickedZooms.has(i)); pickZoom(-1, false); renderZooms(); if (gone > 1) toast(`${gone} zooms removed`); };
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
  if (selectedZoom < 0 || selectedBlur >= 0 || selectedCallout >= 0) return;
  e.stopPropagation();
  const r = $('#clip').getBoundingClientRect(), vw = video.videoWidth, vh = video.videoHeight;
  const src = StillZoom.source(vw, vh, StillZoom.at(zooms, video.currentTime));
  const x = (src.x + (e.clientX - r.left) / r.width * src.w) / vw, y = (src.y + (e.clientY - r.top) / r.height * src.h) / vh;
  changeZoom({ x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) });
}, true);

// ---- Undo ---------------------------------------------------------------------------------------

// Every settled change (a pause of 0.4 s, so one drag is one step) is a step back. Undo and Redo name what they
// changed and open its tab, so the change is in view.
const undoStack = [], redoStack = [];
let lastSnap = null;
const snapshot = () => ({ trim: { ...trim }, cuts: [...cuts], skims: [...skims], zooms: [...zooms], captions: [...captions], music, callouts: [...callouts], chapters: [...chapters], blurs: [...blurs], opening, closing, bg: { ...bg }, showClicks, cursorFx: { ...cursorFx } });
const PARTS = { trim: ['trim', 'trim'], cuts: ['cut', 'trim'], skims: ['fast-forward', 'trim'], zooms: ['zoom', 'zoom'], captions: ['text', 'text'], music: ['music', 'sound'], callouts: ['callout', 'callouts'], chapters: ['chapter', 'chapters'], blurs: ['blur', 'blur'], opening: ['opening', 'ends'], closing: ['closing', 'ends'], bg: ['background', null], showClicks: ['click rings', 'zoom'], cursorFx: ['cursor', 'cursor'] };
// The parts that differ between two snapshots. A background picture is compared by reference: it can be large.
function changed(a, b) {
  return Object.keys(PARTS).filter((key) => (key === 'bg'
    ? a.bg.custom !== b.bg.custom || JSON.stringify({ ...a.bg, custom: 0 }) !== JSON.stringify({ ...b.bg, custom: 0 })
    : JSON.stringify(a[key]) !== JSON.stringify(b[key])));
}
function remember() {
  const now = snapshot();
  if (lastSnap && changed(now, lastSnap).length) { undoStack.push(lastSnap); if (undoStack.length > 200) undoStack.shift(); redoStack.length = 0; }
  lastSnap = now; renderUndo();
}
function renderUndo() {
  $('#undo').disabled = !undoStack.length; $('#redo').disabled = !redoStack.length;
}
async function step(from, to, verb) {
  clearTimeout(saveTimer); remember(); // A change still settling counts as a step of its own.
  if (!from.length) return;
  const target = from.pop(), current = snapshot(), parts = changed(current, target);
  to.push(current);
  trim = { ...target.trim }; cuts = [...target.cuts]; skims = [...target.skims]; selectedSkim = -1; zooms = [...target.zooms]; captions = [...target.captions]; callouts = [...target.callouts];
  chapters = [...target.chapters]; blurs = [...target.blurs]; opening = target.opening; closing = target.closing; showClicks = target.showClicks;
  cursorFx = { ...target.cursorFx };
  const musicMoved = music?.path !== target.music?.path, pictureMoved = bg.custom !== target.bg.custom;
  music = target.music; bg = { ...target.bg };
  lastSnap = snapshot();
  selectedCaption = selectedBlur = selectedCallout = selectedChapter = -1; pickZoom(-1, false); cutStart = null;
  if (musicMoved) await loadMusic();
  if (pictureMoved) await loadPicture();
  $('#opening').value = opening; $('#closing').value = closing;
  renderMusic(false); renderCallouts(false); renderChapters(false); renderBlurs(); renderCaptions(); render(); renderBackground(); renderZooms();
  if (hasBg() && $('#backdrop').hidden) { $('#backdrop').hidden = false; $('#background').setAttribute('aria-expanded', 'true'); }
  const first = PARTS[parts[0]];
  if (first?.[1]) showTab(first[1]);
  if (first) toast(`${verb} ${[...new Set(parts.map((key) => PARTS[key][0]))].join(', ')}`);
  renderUndo();
}
const undo = () => step(undoStack, redoStack, 'Undid');
const redo = () => step(redoStack, undoStack, 'Redid');
$('#undo').onclick = undo; $('#redo').onclick = redo;
addEventListener('keydown', (e) => {
  if (job || !(e.ctrlKey || e.metaKey) || e.altKey || e.target.closest('input, textarea, select')) return;
  const key = e.key.toLowerCase();
  if (key === 'z' && !e.shiftKey) { e.preventDefault(); undo(); }
  else if ((key === 'z' && e.shiftKey) || key === 'y') { e.preventDefault(); redo(); }
});

// ---- Tool tabs ----------------------------------------------------------------------------------

// One group of tools shows at a time. Each tab carries a count of what it holds, so nothing is out of sight for
// long, and picking anything on the timeline opens its tab.
let tab = localStorage.getItem('still.videoTab') || 'trim';
function showTab(name) {
  if (!name || $(`#tabs [data-tab="${name}"]`)?.hidden) name = 'trim';
  tab = name; localStorage.setItem('still.videoTab', name);
  $$('#tabs [data-tab]').forEach((b) => { const on = b.dataset.tab === name; b.setAttribute('aria-selected', String(on)); b.tabIndex = on ? 0 : -1; });
  $$('#tools [data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== name; });
  $$('#tools .lane').forEach((l) => l.classList.toggle('current', l.dataset.tab === name));
}
function renderTabs() {
  const counts = { trim: cuts.length + skims.length, zoom: zooms.length, text: captions.length, callouts: callouts.length, blur: blurs.length, chapters: chapters.length, sound: music ? 1 : 0, ends: (opening !== 'none') + (closing !== 'none') };
  for (const [name, n] of Object.entries(counts)) $(`#count${name[0].toUpperCase()}${name.slice(1)}`).textContent = n ? String(n) : '';
}
$$('#tabs [data-tab]').forEach((b) => { b.onclick = () => showTab(b.dataset.tab); });
$('#tabs').addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  const open = $$('#tabs [data-tab]').filter((b) => !b.hidden), at = open.findIndex((b) => b.dataset.tab === tab);
  const next = open[(at + (e.key === 'ArrowRight' ? 1 : -1) + open.length) % open.length];
  showTab(next.dataset.tab); next.focus(); e.preventDefault();
});
// Picking something on a lane, a chapter flag or a cut opens the tab it belongs to.
$$('#tools .lane').forEach((l) => l.addEventListener('click', () => showTab(l.dataset.tab)));
$('#chapters').addEventListener('click', () => showTab('chapters'));
$('#cuts').addEventListener('click', () => showTab('trim'));
// A shortcut works from any tab, and opens the one its tool lives on.
function press(selector) {
  const b = $(selector);
  if (b.disabled) return;
  showTab(b.closest('[data-panel]')?.dataset.panel || tab); b.click();
}
showTab(tab);

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
  else if (!video.paused) { const next = StillTrim.skip(video.currentTime, cuts); if (next !== video.currentTime) video.currentTime = next; }
  const rate = StillTrim.skimAt(video.currentTime, skims);
  if (video.playbackRate !== rate) { video.playbackRate = rate; video.preservesPitch = true; }
  video.volume = voiceLevel(video.currentTime);
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
$('#reset').onclick = () => { trim = StillTrim.full(duration); cuts = []; cutStart = null; render(); };
$('#gifWidth').onchange = $('#gifFps').onchange = renderGifHint;
$('#exportGif').onclick = () => { renderGifHint(); $('#gifSheet').hidden = false; $('#gifGo').focus(); };
$('#gifCancel').onclick = () => { $('#gifSheet').hidden = true; };
$('#gifSheet').addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); $('#gifSheet').hidden = true; } });
$('#errorClose').onclick = () => { $('#error').hidden = true; };
$('#errorPlayer').onclick = () => still.send('library:play', id);
$('#cancel').onclick = () => { if (job) job.abort(); };

addEventListener('keydown', (e) => {
  if (job || e.metaKey || e.ctrlKey || e.altKey || e.target.closest('button, select, input')) return;
  if (e.key === ' ') { e.preventDefault(); togglePlay(); }
  else if (e.key === 'i' || e.key === 'I') press('#setIn');
  else if (e.key === 'o' || e.key === 'O') press('#setOut');
  else if (e.key === 'z' || e.key === 'Z') press('#addZoom');
  else if (e.key === 'x' || e.key === 'X') press('#cut');
  else if (e.key === 's' || e.key === 'S') press('#addSkim');
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedSkim >= 0) press('#skimRemove');
  else if ((e.key === 'f' || e.key === 'F') && !$('#saveFrame').disabled) $('#saveFrame').click();
  else if (e.key === 't' || e.key === 'T') { e.preventDefault(); press('#addCaption'); }
  else if (e.key === 'Escape' && cutStart !== null) { cutStart = null; render(); }
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedCallout >= 0) press('#calloutRemove');
  else if (e.key === 'a' || e.key === 'A') press('#addArrow');
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedChapter >= 0) press('#chapterRemove');
  else if (e.key === 'm' || e.key === 'M') { e.preventDefault(); press('#addChapter'); }
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedBlur >= 0) press('#blurRemove');
  else if (e.key === 'b' || e.key === 'B') press('#addBlur');
  else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedCaption >= 0) press('#captionRemove');
  else if ((e.key === 'Delete' || e.key === 'Backspace') && pickedZooms.size) press('#zoomRemove');
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
// The frames to record, at `size` (the export's chosen size): straight from the player when nothing is drawn on
// them and the size is unchanged, otherwise through a canvas.
function captureSource(player, size, musicBuffer = null) {
  const F = StillBackdrop.videoFrame(player.videoWidth, player.videoHeight, bg);
  const out = size || { width: F.w, height: F.h }, scaled = out.width < F.w - 1 || out.height < F.h - 1;
  if (player.captureStream && !needsCanvas() && !scaled) return { stream: player.captureStream(), stop() {} };
  const canvas = el('canvas', { width: out.width, height: out.height }), ctx = canvas.getContext('2d', { alpha: false });
  ctx.imageSmoothingQuality = 'high';
  const draw = () => { ctx.setTransform(out.width / F.w, 0, 0, out.height / F.h, 0, 0); drawFrame(ctx, player, F); };
  draw();
  const timer = setInterval(draw, 1000 / 30);
  let audio = null, sound, gain = null, musicGain = null, musicSource = null;
  // The opening and closing fade the sound too, and music is mixed in, so they go through Web Audio.
  if (player.captureStream && !StillTransitions.active(opening, closing) && !musicBuffer && !skims.length) sound = player.captureStream().getAudioTracks();
  else {
    player.muted = false;
    audio = new AudioContext(); const mix = audio.createMediaStreamDestination();
    gain = audio.createGain(); audio.createMediaElementSource(player).connect(gain).connect(mix);
    if (musicBuffer) {
      musicSource = audio.createBufferSource(); musicSource.buffer = musicBuffer; musicSource.loop = true;
      musicGain = audio.createGain(); musicGain.gain.value = 0; musicSource.connect(musicGain).connect(mix);
    }
    sound = mix.stream.getAudioTracks();
  }
  const level = setInterval(() => {
    if (gain) gain.gain.value = ends(player.currentTime).level * voiceLevel(player.currentTime);
    if (musicGain) musicGain.gain.value = musicLevel(player.currentTime);
  }, 20);
  const tracks = [...canvas.captureStream(30).getVideoTracks(), ...sound];
  return {
    stream: new MediaStream(tracks),
    // The music starts with the recording, and holds while a cut is skipped so it stays in step with the picture.
    start() { if (musicSource) musicSource.start(); },
    hold(on) { if (audio) (on ? audio.suspend() : audio.resume()).catch(() => {}); },
    stop() { clearInterval(timer); clearInterval(level); if (audio) audio.close(); },
  };
}

async function recordClip(run, type, plan) {
  const clip = { ...trim }, clipCuts = cuts.map((c) => ({ ...c })), clipSkims = skims.map((k) => ({ ...k })), segments = StillTrim.kept(clip, clipCuts, clipSkims), total = StillTrim.keptLength(clip, clipCuts, clipSkims), player = await unseenPlayer();
  await seek(player, clip.start);
  if (run.cancelled) return null;
  let musicBuffer = null;
  if (music) {
    try { const context = new AudioContext(); try { musicBuffer = await context.decodeAudioData(await (await fetch(still.fileUrl(music.path))).arrayBuffer()); } finally { context.close(); } }
    catch { setSheetNote('The music couldn’t be read, so this export has none.'); }
  }
  const capture = captureSource(player, plan.size, musicBuffer), chunks = [];
  const recorder = new MediaRecorder(capture.stream, { mimeType: type, videoBitsPerSecond: plan.bitrate });
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
    // A faster export plays the recording faster as it records; the voice keeps its pitch.
    player.playbackRate = plan.speed || 1; player.preservesPitch = true;
    // Playback starts first, so a slow start can't become a frozen opening frame.
    await player.play();
    if (run.cancelled) return null;
    recorder.start(1000); capture.start?.();
    // A cut is skipped with the recorder paused, so the finished video runs straight across it.
    let jumping = false;
    watcher = setInterval(() => {
      if (jumping) return;
      setProgress(StillTrim.outputAt(player.currentTime, segments) / total * 0.98);
      if (player.ended || player.currentTime >= clip.end) return finish();
      // A fast-forward plays the recording faster as it records, so it takes less of the finished video.
      const rate = (plan.speed || 1) * StillTrim.skimAt(player.currentTime, clipSkims);
      if (player.playbackRate !== rate) player.playbackRate = rate;
      const next = StillTrim.skip(player.currentTime, clipCuts);
      if (next !== player.currentTime && recorder.state === 'recording') {
        jumping = true; recorder.pause(); player.pause(); capture.hold?.(true);
        player.addEventListener('seeked', () => { capture.hold?.(false); player.play().catch(() => {}); recorder.resume(); jumping = false; }, { once: true });
        player.currentTime = next;
      }
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

// Export options, asked each time Export Video is chosen and remembered for next time: a size (the shorter side
// brought down to 2160, 1440, 1080, 720 or 480 pixels, never up) and a quality (Maximum, the Mac's High,
// Balanced and Smaller File, or a bitrate preset from Settings → Recording).
let prefs = {};
const exportChoice = (() => { try { return JSON.parse(localStorage.getItem('stillVideoExport')) || {}; } catch { return {}; } })();
const sourceFrame = () => StillBackdrop.videoFrame(video.videoWidth, video.videoHeight, bg);
function exportPlan() {
  const F = sourceFrame(), limit = Number($('#exportSize').value) || 0, quality = $('#exportQuality').value || 'original';
  const size = StillGeometry.exportSize(F.w, F.h, limit), scaled = size.width < F.w - 1 || size.height < F.h - 1;
  const bitrate = quality === 'original' ? Math.min(100_000_000, StillGeometry.videoBitrate(size.width, size.height, 30, 'high') * 1.5) : StillGeometry.videoBitrate(size.width, size.height, 30, quality);
  const speed = [1, 1.25, 1.5, 2, 3].includes(Number($('#exportSpeed').value)) ? Number($('#exportSpeed').value) : 1;
  const copy = isWhole() && !needsCanvas() && !scaled && quality === 'original' && speed === 1;
  return { limit, quality, size, scaled, bitrate, copy, speed, seconds: StillTrim.keptLength(trim, cuts, skims) / speed };
}
function renderExportSummary() {
  const plan = exportPlan();
  $('#exportSummary').textContent = plan.copy ? `${plan.size.width} × ${plan.size.height} · an exact copy of the recording`
    : `${plan.size.width} × ${plan.size.height} · ${(plan.bitrate / 1e6).toFixed(1)} Mbps · ${StillTrim.clock(plan.seconds)} long · about ${StillGeometry.sizeLabel(StillGeometry.estimateBytes(plan.bitrate, plan.seconds))}`;
}
function openExportOptions() {
  const presets = (Array.isArray(prefs.recording?.bitratePresets) ? prefs.recording.bitratePresets : []).filter((p) => p && String(p.name || '').trim() && Number(p.megabits) > 0);
  const options = [['original', 'Maximum'], ['high', 'High'], ['balanced', 'Balanced'], ['compact', 'Smaller File'],
    ...presets.map((p) => [`bitrate:${Math.round(Math.min(100, Math.max(1, Number(p.megabits))) * 1e6)}`, `${p.name} (${Math.min(100, Math.max(1, Number(p.megabits)))} Mbps)`])];
  $('#exportQuality').replaceChildren(...options.map(([value, text]) => el('option', { value }, text)));
  $('#exportQuality').value = options.some(([v]) => v === exportChoice.quality) ? exportChoice.quality : 'original';
  $('#exportSize').value = String(exportChoice.size || 0);
  if (!$('#exportSize').value) $('#exportSize').value = '0';
  $('#exportSpeed').value = String(exportChoice.speed || 1); if (!$('#exportSpeed').value) $('#exportSpeed').value = '1';
  renderExportSummary();
  $('#exportSheet').hidden = false; $('#exportGo').focus();
}
$('#exportSize').onchange = $('#exportQuality').onchange = $('#exportSpeed').onchange = renderExportSummary;
$('#exportCancel').onclick = () => { $('#exportSheet').hidden = true; };
$('#exportSheet').addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); $('#exportSheet').hidden = true; } });
$('#exportVideo').onclick = openExportOptions;
$('#exportGo').onclick = () => {
  const plan = exportPlan();
  exportChoice.size = plan.limit; exportChoice.quality = plan.quality; exportChoice.speed = plan.speed;
  try { localStorage.setItem('stillVideoExport', JSON.stringify(exportChoice)); } catch { /* remembered for this window only */ }
  $('#exportSheet').hidden = true;
  const ext = item.path.split('.').pop().toLowerCase();
  if (plan.copy) {
    return runExport('Exporting…', async () => {
      const target = await still.invoke('video:target', ext);
      return target && still.invoke('video:copy');
    });
  }
  const format = StillTrim.recorderType(ext, (type) => !!window.MediaRecorder && MediaRecorder.isTypeSupported(type));
  if (!format.type) return showError('Couldn’t export: this system’s web engine can’t record video, so a trimmed copy can’t be made here. GIF export still works.');
  runExport(needsCanvas() || plan.scaled ? 'Exporting…' : 'Trimming…', async (run) => {
    const target = await still.invoke('video:target', format.ext);
    if (!target || run.cancelled) return null;
    const bytes = await recordClip(run, format.type, plan);
    return bytes && save(bytes);
  });
};

// ---- Pictures from the video -----------------------------------------------------------------------

// The picture at the player's moment, as exported: background, blurs, callouts, captions and the rest.
function framePicture(player, width) {
  const F = StillBackdrop.videoFrame(player.videoWidth, player.videoHeight, bg), k = width ? width / F.w : 1;
  const canvas = el('canvas', { width: Math.round(F.w * k), height: Math.round(F.h * k) }), ctx = canvas.getContext('2d', { alpha: false });
  ctx.imageSmoothingQuality = 'high'; ctx.setTransform(k, 0, 0, k, 0, 0); drawFrame(ctx, player, F);
  return canvas;
}
$('#saveFrame').onclick = async () => {
  pause();
  try {
    const kept = StillTrim.kept(trim, cuts, skims), at = StillChapters.stamp(StillTrim.outputAt(video.currentTime, kept));
    await still.invoke('video:image', framePicture(video).toDataURL('image/png'), `${document.title || 'Recording'} at ${at}`, false);
    toast('Frame saved to History and copied');
  } catch (error) { showError(`Couldn’t save the frame: ${message(error)}`); }
};
$('#storyboard').onclick = () => runExport('Making storyboard…', async (run) => {
  const shots = StillStoryboard.frames(trim, cuts, chapters, { speed: Number(exportChoice.speed) || 1, skims });
  if (!shots.length) throw new Error('There’s nothing kept to show.');
  const player = await unseenPlayer();
  const F = StillBackdrop.videoFrame(player.videoWidth, player.videoHeight, bg), L = StillStoryboard.layout(shots.length, F.w, F.h);
  const sheet = el('canvas', { width: L.width, height: L.height }), ctx = sheet.getContext('2d', { alpha: false });
  ctx.fillStyle = '#16161a'; ctx.fillRect(0, 0, L.width, L.height);
  ctx.font = `600 15px ${getComputedStyle(document.body).fontFamily}`; ctx.textBaseline = 'middle';
  try {
    for (const [i, shot] of shots.entries()) {
      if (run.cancelled) return null;
      await seek(player, shot.time);
      const x = L.gap + (i % L.cols) * (L.tileWidth + L.gap), y = L.gap + Math.floor(i / L.cols) * (L.tileHeight + L.strip + L.gap);
      ctx.save(); ctx.beginPath(); ctx.roundRect(x, y, L.tileWidth, L.tileHeight, 8); ctx.clip();
      ctx.drawImage(framePicture(player, L.tileWidth * 2), x, y, L.tileWidth, L.tileHeight); ctx.restore();
      ctx.fillStyle = '#f5f5f7'; ctx.fillText(shot.label, x + 4, y + L.tileHeight + L.strip / 2, L.tileWidth - 8);
      setProgress((i + 1) / shots.length * 0.95);
    }
  } finally { player.removeAttribute('src'); player.load(); }
  await still.invoke('video:image', sheet.toDataURL('image/png'), `${document.title || 'Recording'} storyboard`, true);
  toast('Storyboard saved to History and opened');
  return null;
});
$('#gifGo').onclick = () => {
  const plan = gifPlan();
  $('#gifSheet').hidden = true;
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
      const segments = StillTrim.kept(trim, cuts, skims), length = StillTrim.keptLength(trim, cuts, skims), samples = StillGIF.sampleTimes(0, length).map((t) => StillTrim.sourceAt(t, segments));
      for (const [i, time] of samples.entries()) {
        const rgba = await grab(time);
        await ask({ type: 'sample', rgba }, [rgba.buffer]);
        setProgress((i + 1) / samples.length * 0.1);
      }
      for (let i = 0; i < plan.frames; i++) {
        const rgba = await grab(StillTrim.sourceAt(i / plan.fps, segments));
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
  cuts = StillTrim.normalizeCuts(Array.isArray(project.cuts) ? project.cuts : [], trim);
  skims = StillTrim.normalizeSkims(Array.isArray(project.skims) ? project.skims : [], trim);
  if (project.bg && (StillBackdrop.GRADIENTS[project.bg.style] || (project.bg.style === 'custom' && project.bg.custom))) bg = { ...NO_BG, ...project.bg };
  await loadPicture();
  zooms = (Array.isArray(project.zooms) ? project.zooms : []).filter((z) => z && z.end > z.start && z.scale >= 1);
  captions = (Array.isArray(project.captions) ? project.captions : []).filter((c) => c && c.end > c.start && typeof c.text === 'string');
  music = project.music && typeof project.music.path === 'string' ? { name: String(project.music.name || 'Music'), path: project.music.path, volume: Math.min(1, Math.max(0, Number(project.music.volume) || 0.3)), duck: project.music.duck !== false, speech: Array.isArray(project.music.speech) ? project.music.speech : [] } : null;
  await loadMusic(); renderMusic(false);
  callouts = (Array.isArray(project.callouts) ? project.callouts : []).filter((c) => c && StillCallouts.KINDS.includes(c.kind) && c.end > c.start);
  renderCallouts(false);
  chapters = (Array.isArray(project.chapters) ? project.chapters : []).filter((c) => c && Number.isFinite(c.time)).map((c) => ({ time: c.time, title: String(c.title || 'Chapter') })).sort((a, b) => a.time - b.time);
  renderChapters(false);
  blurs = (Array.isArray(project.blurs) ? project.blurs : []).filter((b) => b && b.end > b.start).map((b) => ({ start: b.start, end: b.end, ...StillBlurs.fit(b) }));
  renderBlurs();
  opening = StillTransitions.STYLES.includes(project.opening) ? project.opening : 'none'; closing = StillTransitions.STYLES.includes(project.closing) ? project.closing : 'none';
  $('#opening').value = opening; $('#closing').value = closing;
  renderCaptions();
  showClicks = !!project.showClicks;
  if (project.cursorFx && typeof project.cursorFx === 'object') cursorFx = { ...cursorFx, ...project.cursorFx };
  $('#status').hidden = true;
  $$('#play, #setIn, #setOut, #cut, #addSkim, #speedWaits, #findChapters, #exportVideo, #exportGif, #background, #addZoom, #addCaption, #opening, #closing, #tighten, #addBlur, #findPrivate, #addChapter, #chooseMusic, #addArrow, #addBox, #addSpot, #saveFrame, #storyboard').forEach((button) => { button.disabled = false; });
  render(); renderPlayhead(); renderBackground(); renderZooms();
  if (hasBg()) { $('#backdrop').hidden = false; $('#background').setAttribute('aria-expanded', 'true'); }
  fillThumbnails().catch(() => {}); // The film strip is a nicety; trimming works without it.
}

applyTheme().then((loaded) => { prefs = loaded || {}; if (prefs.platform !== 'darwin') addWindowControls(); return open(); })
  .catch((error) => { $('#status').hidden = true; showError(`Couldn’t open this recording: ${message(error)}`, true); });
refreshIcons();
still.on('library:changed', async () => { if (!(await still.invoke('library:get', id))) still.send('window:close'); });
