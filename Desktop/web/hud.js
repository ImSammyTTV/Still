// The recording HUD also does the recording: the system web engine captures the screen,
// a canvas crops it to the selection, and the finished file goes back to Still.
const opts = window.__STILL_PARAMS__ || {};
let recorder, streams = [], chunks = [], cropTimer, audioContext, ext = 'webm';
let start = 0, pausedAt = 0, pausedTotal = 0, paused = false, cancelled = false, finishing = false, trayTime = '';
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

async function begin() {
  const o = opts.options || {};
  if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia || !window.MediaRecorder) throw new Error('Screen recording isn’t supported by this system’s web engine yet.');
  $('#time').textContent = 'Choose a screen…';
  const display = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: o.fps || 30 }, audio: !!o.systemAudio });
  streams.push(display);
  const track = display.getVideoTracks()[0];
  const video = document.createElement('video'); video.muted = true; video.srcObject = new MediaStream([track]); await video.play();
  const r = opts.rect, sx = video.videoWidth / opts.imageWidth, sy = video.videoHeight / opts.imageHeight;
  const full = r.x <= 1 && r.y <= 1 && r.w >= opts.imageWidth - 2 && r.h >= opts.imageHeight - 2;
  let videoTrack = track;
  if (!full) {
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
  const type = pickType(o.format); ext = type.startsWith('video/mp4') ? 'mp4' : 'webm';
  recorder = new MediaRecorder(new MediaStream([videoTrack, ...audio]), { mimeType: type || undefined, videoBitsPerSecond: 12_000_000 });
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  recorder.onstop = finish;
  track.addEventListener('ended', () => stop());
  for (let n = o.countdown || 0; n > 0; n--) { $('#time').textContent = `Starts in ${n}`; await new Promise((res) => setTimeout(res, 1000)); if (cancelled) return finish(); }
  recorder.start(1000); start = performance.now(); $('#time').textContent = '0:00';
  still.invoke('recording:started');
}

function stop() { if (recorder && recorder.state !== 'inactive') recorder.stop(); else finish(); }
async function finish() {
  if (finishing) return; // Stop can arrive twice now that the tray offers it too.
  finishing = true;
  clearInterval(cropTimer);
  streams.forEach((s) => s.getTracks().forEach((t) => t.stop())); audioContext?.close();
  if (cancelled || !chunks.length) return still.invoke('recording:cancel');
  $('#time').textContent = 'Saving…';
  const duration = start ? (performance.now() - start - pausedTotal) / 1000 : 0;
  const bytes = new Uint8Array(await new Blob(chunks, { type: recorder.mimeType }).arrayBuffer());
  await still.raw('recording_save', bytes, { 'x-ext': ext, 'x-duration': String(duration) });
}

function togglePause() {
  if (!recorder) return;
  if (recorder.state === 'recording') { recorder.pause(); paused = true; pausedAt = performance.now(); }
  else if (recorder.state === 'paused') { recorder.resume(); paused = false; pausedTotal += performance.now() - pausedAt; }
  $('#hud').classList.toggle('paused', paused);
  $('#pause').innerHTML = icon(paused ? 'play' : 'pause'); $('#pause').title = paused ? 'Resume' : 'Pause'; refreshIcons();
}

$('#stop').onclick = () => stop();
$('#pause').onclick = () => togglePause();
$('#cancel').onclick = () => { cancelled = true; stop(); };
$('#restart').onclick = () => { if (!recorder) return; chunks = []; recorder.stop(); recorder.onstop = () => { chunks = []; recorder.start(1000); start = performance.now(); pausedTotal = 0; recorder.onstop = finish; }; };
still.on('hud:stop', () => stop());
begin().catch((error) => still.invoke('recording:error', error.message || String(error)));
