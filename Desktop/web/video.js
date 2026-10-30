// The video editor: play a recording, choose the part to keep, export it as a video or a GIF.
//
// How trimming works, and its limits: a web engine has no way to cut a WebM or MP4 without re-encoding it,
// and the recorder writes keyframes too rarely to cut cleanly at the container level. So a trimmed export
// plays the kept part in an unseen player and records that with MediaRecorder, the same engine and bitrate
// as the original recording. That means it runs in real time, is a second generation of the picture, and
// In and Out land within a frame or two. It pauses while the window is hidden, because the page's timers
// slow down then. An untrimmed export skips all this and copies the file exactly. Trim points aren't saved
// with the recording; only the exported file keeps them.
const id = params.get('id');
const video = $('#video');
const BITRATE = 12_000_000; // Matches the recording HUD.
const THUMBNAILS = 9;
let item, source, duration = 0, trim = { start: 0, end: 0 }, job = null;

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
}

function renderPlayhead() {
  $('#playhead').style.left = `${StillTrim.position(video.currentTime, duration) * 100}%`;
  $('#now').textContent = StillTrim.clock(video.currentTime);
}

function gifPlan() {
  return StillGIF.plan({ duration: StillTrim.length(trim), fps: Number($('#gifFps').value), width: Number($('#gifWidth').value), sourceWidth: video.videoWidth, sourceHeight: video.videoHeight });
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
function captureSource(player) {
  if (player.captureStream) return { stream: player.captureStream(), stop() {} };
  player.muted = false;
  const canvas = el('canvas', { width: player.videoWidth, height: player.videoHeight }), ctx = canvas.getContext('2d', { alpha: false });
  const draw = () => ctx.drawImage(player, 0, 0, canvas.width, canvas.height);
  draw();
  const timer = setInterval(draw, 1000 / 30);
  const audio = new AudioContext(), mix = audio.createMediaStreamDestination();
  audio.createMediaElementSource(player).connect(mix);
  const tracks = [...canvas.captureStream(30).getVideoTracks(), ...mix.stream.getAudioTracks()];
  return { stream: new MediaStream(tracks), stop() { clearInterval(timer); audio.close(); } };
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
  if (StillTrim.isFull(trim, duration)) {
    return runExport('Exporting…', async () => {
      const target = await still.invoke('video:target', ext);
      return target && still.invoke('video:copy');
    });
  }
  const format = StillTrim.recorderType(ext, (type) => !!window.MediaRecorder && MediaRecorder.isTypeSupported(type));
  if (!format.type) return showError('Couldn’t export: this system’s web engine can’t record video, so a trimmed copy can’t be made here. GIF export still works.');
  runExport('Trimming…', async (run) => {
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
    const grab = async (time) => {
      await seek(player, time);
      ctx.drawImage(player, 0, 0, plan.width, plan.height);
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
  trim = StillTrim.full(duration);
  $('#status').hidden = true;
  $$('#play, #setIn, #setOut, #exportVideo, #exportGif').forEach((button) => { button.disabled = false; });
  render(); renderPlayhead();
  fillThumbnails().catch(() => {}); // The film strip is a nicety; trimming works without it.
}

applyTheme().then((prefs) => { if (prefs.platform !== 'darwin') addWindowControls(); return open(); })
  .catch((error) => { $('#status').hidden = true; showError(`Couldn’t open this recording: ${message(error)}`, true); });
refreshIcons();
still.on('library:changed', async () => { if (!(await still.invoke('library:get', id))) still.send('window:close'); });
