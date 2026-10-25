// Runs in a hidden window: captures the display, crops it to the selection and encodes it.
let recorder, streams = [], chunks = [], cropTimer, audioContext, started = 0, pausedAt = 0, pausedTotal = 0, cancelled = false, ext = 'webm';

function pickType(format) {
  const mp4 = ['video/mp4;codecs=avc1.640028,mp4a.40.2', 'video/mp4;codecs=avc1,opus', 'video/mp4'];
  const webm = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'];
  for (const type of format === 'mp4' ? [...mp4, ...webm] : webm) if (MediaRecorder.isTypeSupported(type)) return type;
  return '';
}

async function start(opts) {
  const display = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: opts.fps }, audio: !!opts.systemAudio });
  streams.push(display);
  const track = display.getVideoTracks()[0];
  const video = document.createElement('video'); video.muted = true; video.srcObject = new MediaStream([track]); await video.play();
  const full = opts.rect.x <= 0 && opts.rect.y <= 0 && opts.rect.w >= opts.width - 1 && opts.rect.h >= opts.height - 1;
  let videoTrack = track;
  if (!full) {
    const sx = video.videoWidth / opts.width, sy = video.videoHeight / opts.height;
    const src = { x: opts.rect.x * sx, y: opts.rect.y * sy, w: opts.rect.w * sx, h: opts.rect.h * sy };
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(2, Math.round(src.w / 2) * 2); canvas.height = Math.max(2, Math.round(src.h / 2) * 2);
    const ctx = canvas.getContext('2d', { alpha: false });
    const draw = () => ctx.drawImage(video, src.x, src.y, src.w, src.h, 0, 0, canvas.width, canvas.height);
    draw(); cropTimer = setInterval(draw, 1000 / opts.fps);
    videoTrack = canvas.captureStream(opts.fps).getVideoTracks()[0];
  }
  const audioTracks = [];
  const sources = [...display.getAudioTracks()];
  if (opts.microphone) {
    try { const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }); streams.push(mic); sources.push(...mic.getAudioTracks()); }
    catch { still.send('recorder:warning', 'The microphone could not be used.'); }
  }
  if (sources.length) {
    audioContext = new AudioContext(); const mix = audioContext.createMediaStreamDestination();
    for (const t of sources) audioContext.createMediaStreamSource(new MediaStream([t])).connect(mix);
    audioTracks.push(...mix.stream.getAudioTracks());
  }
  const type = pickType(opts.format); ext = type.startsWith('video/mp4') ? 'mp4' : 'webm';
  recorder = new MediaRecorder(new MediaStream([videoTrack, ...audioTracks]), { mimeType: type || undefined, videoBitsPerSecond: 12_000_000 });
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  recorder.onstop = finish;
  track.addEventListener('ended', () => stop());
  for (let n = opts.countdown || 0; n > 0; n--) { still.send('recorder:countdown', n); await new Promise((r) => setTimeout(r, 1000)); if (cancelled) return finish(); }
  recorder.start(1000); started = performance.now();
  still.send('recorder:started');
}

function stop() { if (recorder && recorder.state !== 'inactive') recorder.stop(); else finish(); }
async function finish() {
  clearInterval(cropTimer);
  streams.forEach((s) => s.getTracks().forEach((t) => t.stop())); audioContext?.close();
  const duration = started ? (performance.now() - started - pausedTotal) / 1000 : 0;
  if (cancelled || !chunks.length) return still.send('recorder:data', null, ext, 0);
  const blob = new Blob(chunks, { type: recorder.mimeType });
  still.send('recorder:data', new Uint8Array(await blob.arrayBuffer()), ext, duration);
}

still.on('recorder:start', (opts) => start(opts).catch((error) => still.send('recorder:error', error.message || String(error))));
still.on('recorder:stop', () => stop());
still.on('recorder:cancel', () => { cancelled = true; stop(); });
still.on('recorder:pause', () => {
  if (!recorder) return;
  if (recorder.state === 'recording') { recorder.pause(); pausedAt = performance.now(); still.send('recorder:paused', true); }
  else if (recorder.state === 'paused') { recorder.resume(); pausedTotal += performance.now() - pausedAt; still.send('recorder:paused', false); }
});
