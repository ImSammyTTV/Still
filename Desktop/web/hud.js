// The recording HUD also does the recording: the system web engine captures the screen,
// a canvas crops it to the selection, and the finished file goes back to Still.
const opts = window.__STILL_PARAMS__ || {};
let recorder, streams = [], cropTimer, audioContext, ext = 'webm';
let start = 0, pausedAt = 0, pausedTotal = 0, paused = false, cancelled = false, finishing = false, finishedAt = 0, trayTime = '';
let media = null, triedWebm = false, failure = '';
// Each second of video goes to Still as soon as the recorder hands it over, in order, and Still appends it to a
// file. Nothing waits in memory for the end, so stopping is quick however long the recording ran, and a
// recording that is interrupted still exists on disk up to its last second.
let written = 0, writes = Promise.resolve();
const base64 = (blob) => new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(String(reader.result).split(',')[1] || ''); reader.onerror = () => reject(reader.error || new Error('The recorded data couldn’t be read.')); reader.readAsDataURL(blob); });
function queueChunk(blob) {
  writes = writes.then(async () => { await still.invoke('recording:chunk', await base64(blob), ext); written += blob.size; })
    .catch((error) => { failure = failure || (error && error.message) || String(error); });
}
function discardWritten() { written = 0; writes = writes.then(() => still.invoke('recording:reset')).catch(() => {}); }

// The recorder can fail after it has started (most often an MP4 encoder that this machine doesn't really have).
// Without a handler that failure was silent: the stop produced no data and the HUD quietly cancelled.
function startRecorder(type) {
  ext = type.startsWith('video/mp4') ? 'mp4' : 'webm';
  recorder = new MediaRecorder(media, { mimeType: type || undefined, videoBitsPerSecond: 12_000_000 });
  recorder.ondataavailable = (e) => { if (e.data.size) queueChunk(e.data); };
  recorder.onstop = finish;
  recorder.onerror = (e) => {
    const reason = (e.error && (e.error.message || e.error.name)) || 'The video encoder stopped unexpectedly.';
    if (!written && ext === 'mp4' && !triedWebm) {
      // Nothing recorded yet, so start over in WebM, which every engine can encode. The failed recorder's own
      // stop event follows this error; ignoring it keeps the two recorders from both finishing.
      triedWebm = true; recorder.onstop = null; recorder.ondataavailable = null; discardWritten();
      setTimeout(() => { startRecorder(pickType('webm')); recorder.start(1000); start = performance.now(); pausedTotal = 0; toast('MP4 isn’t available here, so this is recording as WebM'); }, 0);
      return;
    }
    failure = reason;
    stop();
  };
}
refreshIcons();

setInterval(() => {
  if (!start) return;
  const now = paused ? pausedAt : performance.now();
  const seconds = Math.max(0, Math.floor((now - start - pausedTotal) / 1000));
  $('#time').textContent = StillGeometry.formatDuration(seconds);
  if (trayTime !== `${seconds} ${paused}`) { trayTime = `${seconds} ${paused}`; still.send('recording:tick', seconds, paused); }
}, 250);

function pickType(format) {
  const mp4 = ['video/mp4;codecs=avc1.640028,mp4a.40.2', 'video/mp4;codecs=avc1,opus', 'video/mp4'];
  const webm = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'];
  for (const type of format === 'mp4' ? [...mp4, ...webm] : webm) if (window.MediaRecorder && MediaRecorder.isTypeSupported(type)) return type;
  return '';
}

// Still's own recorder (Windows): Still captures and encodes by itself, so there is no system picker and no
// "sharing your screen" bar, and this page is only the controls. If it can't start, the web engine records instead.
let native = false, nativeLive = false;
// On Windows, an error from the system recorder also says why Still's own recorder wasn't the one recording.
const withWhy = (message) => (still.platform === 'win32' && opts.nativeWhy ? `${message} (Still’s own recorder wasn’t used: ${opts.nativeWhy})` : message);
async function beginNative() {
  native = true;
  const o = opts.options || {};
  await still.invoke('recording:prepared').catch(() => {}); // The camera and overlays are extras: never a reason not to record.
  for (let n = o.countdown || 0; n > 0; n--) { $('#time').textContent = `Starts in ${n}`; await new Promise((res) => setTimeout(res, 1000)); if (cancelled || finishing) break; }
  if (cancelled || finishing) return still.invoke('recording:cancel'); // Stopped before anything was recorded.
  try {
    await still.invoke('recording:begin');
  } catch (error) {
    // Say why, rather than quietly opening the system picker this recorder exists to avoid.
    return still.invoke('recording:error', `Still’s recorder couldn’t start: ${error && error.message ? error.message : String(error)}`);
  }
  nativeLive = true; start = performance.now(); $('#time').textContent = '0:00';
  still.invoke('recording:started');
}

async function begin() {
  if (opts.native) return beginNative();
  if (reloadForMedia()) return;
  const o = opts.options || {};
  if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia || !window.MediaRecorder) throw new Error('Screen recording isn’t supported by this system’s web engine yet.');
  $('#time').textContent = opts.selectedWindow ? 'Choose the window…' : 'Choose a screen…';
  const display = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: o.fps || 30, displaySurface: opts.selectedWindow ? 'window' : 'monitor' }, audio: !!o.systemAudio });
  streams.push(display);
  const track = display.getVideoTracks()[0];
  const displaySurface = track.getSettings().displaySurface;
  if (!StillCaptureInput.recordingSourceAllowed(opts.selectedWindow, displaySurface)) throw new Error('Window recording needs a window source. Choose your window in the system sharing picker, or use area recording instead.');
  const video = document.createElement('video'); video.muted = true; video.srcObject = new MediaStream([track]); await video.play();
  const r = opts.rect, sx = video.videoWidth / opts.imageWidth, sy = video.videoHeight / opts.imageHeight;
  const full = r.x <= 1 && r.y <= 1 && r.w >= opts.imageWidth - 2 && r.h >= opts.imageHeight - 2;
  let videoTrack = track;
  if (StillCaptureInput.shouldCrop(displaySurface, full)) {
    const src = { x: r.x * sx, y: r.y * sy, w: r.w * sx, h: r.h * sy };
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(2, Math.round(src.w / 2) * 2); canvas.height = Math.max(2, Math.round(src.h / 2) * 2);
    const ctx = canvas.getContext('2d', { alpha: false });
    const draw = () => ctx.drawImage(video, src.x, src.y, src.w, src.h, 0, 0, canvas.width, canvas.height);
    draw(); cropTimer = setInterval(draw, 1000 / (o.fps || 30));
    videoTrack = canvas.captureStream(o.fps || 30).getVideoTracks()[0];
  }
  const sources = [...display.getAudioTracks()];
  if (o.microphone) {
    try { const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }); streams.push(mic); sources.push(...mic.getAudioTracks()); }
    catch { toast('The microphone could not be used'); }
  }
  const audio = [];
  if (sources.length) {
    audioContext = new AudioContext(); const mix = audioContext.createMediaStreamDestination();
    for (const t of sources) audioContext.createMediaStreamSource(new MediaStream([t])).connect(mix);
    audio.push(...mix.stream.getAudioTracks());
  }
  media = new MediaStream([videoTrack, ...audio]);
  startRecorder(pickType(o.format));
  track.addEventListener('ended', () => stop());
  await still.invoke('recording:prepared').catch(() => {}); // The camera and overlays are extras: never a reason not to record.
  for (let n = o.countdown || 0; n > 0; n--) { $('#time').textContent = `Starts in ${n}`; await new Promise((res) => setTimeout(res, 1000)); if (cancelled || finishing) break; }
  if (cancelled || finishing) return finish();
  recorder.start(1000); start = performance.now(); $('#time').textContent = '0:00';
  still.invoke('recording:started');
}

function stop() {
  still.send('recording:listen', false); // Keys stop here, not when the file has finished saving.
  if (native) {
    if (finishing) return;
    finishing = true;
    if (!nativeLive) return; // Still counting down: beginNative sees this and ends the recording.
    $('#time').textContent = 'Saving…';
    // Still finishes the file, stores it and closes these controls; a failure arrives as a notification.
    still.invoke(cancelled ? 'recording:cancel' : 'recording:stop').catch(() => {});
    return;
  }
  // A second Stop while saving has stalled is a way out, never a dead button: Still keeps what was written.
  if (finishing) { if (finishedAt && performance.now() - finishedAt > 5000) still.invoke('recording:error', failure || 'Saving didn’t finish.', 'save').catch(() => {}); return; }
  if (recorder && recorder.state !== 'inactive') recorder.stop(); else finish();
}
async function finish() {
  if (finishing) return; // Stop can arrive twice now that the tray offers it too.
  finishing = true; finishedAt = performance.now();
  still.send('recording:finished'); // After the recorder, so the bubble doesn't vanish in the last frames.
  clearInterval(cropTimer);
  streams.forEach((s) => s.getTracks().forEach((t) => t.stop())); audioContext?.close();
  if (cancelled) { await writes; return still.invoke('recording:cancel'); }
  $('#time').textContent = 'Saving…';
  const duration = start ? (performance.now() - start - pausedTotal) / 1000 : 0;
  await writes; // The last second is usually still on its way.
  // No data is a failure to report, never something to drop quietly.
  if (!written) return still.invoke('recording:error', withWhy(failure || 'No video was captured. Try the WebM format in Settings → Recording.'), 'save');
  try {
    await still.invoke('recording:save', ext, duration);
  } catch (error) {
    // The HUD would otherwise sit on "Saving…" for good with nothing to show for the recording.
    await still.invoke('recording:error', withWhy(`${failure ? failure + ' ' : ''}${error && error.message ? error.message : String(error)}`), 'save');
  }
}

function togglePause() {
  if (native) {
    if (!nativeLive || finishing) return;
    paused = !paused;
    if (paused) pausedAt = performance.now(); else pausedTotal += performance.now() - pausedAt;
    still.invoke('recording:pause', paused).catch(() => {});
    return showPaused();
  }
  if (!recorder || recorder.state === 'inactive') return; // Nothing to pause in the countdown, and nothing to listen for yet.
  if (recorder.state === 'recording') { recorder.pause(); paused = true; pausedAt = performance.now(); }
  else if (recorder.state === 'paused') { recorder.resume(); paused = false; pausedTotal += performance.now() - pausedAt; }
  showPaused();
}
function showPaused() {
  still.send('recording:listen', !paused);
  $('#hud').classList.toggle('paused', paused);
  $('#pause').innerHTML = icon(paused ? 'play' : 'pause'); $('#pause').title = paused ? 'Resume' : 'Pause'; refreshIcons();
}

$('#stop').onclick = () => stop();
$('#pause').onclick = () => togglePause();
$('#cancel').onclick = () => { cancelled = true; stop(); };
$('#restart').onclick = () => {
  if (native) {
    if (!nativeLive || finishing) return;
    still.invoke('recording:restart').catch(() => {});
    start = performance.now(); pausedTotal = 0; if (paused) { paused = false; still.invoke('recording:pause', false).catch(() => {}); showPaused(); }
    return;
  }
  if (!recorder) return; recorder.stop(); recorder.onstop = () => { discardWritten(); recorder.start(1000); start = performance.now(); pausedTotal = 0; recorder.onstop = finish; if (paused) { paused = false; showPaused(); } }; };
still.on('hud:stop', () => stop());
if (opts.stopShortcut) still.invoke('shortcut:label', opts.stopShortcut).then((label) => { const stop = $('#stop'); stop.title = `Stop and save (${label})`; stop.setAttribute('aria-label', stop.title); }).catch(() => {});
begin().catch((error) => still.invoke('recording:error', withWhy(error.message || String(error))));
