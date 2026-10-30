// The camera bubble. It's an ordinary window on screen, so the screen capture records it where it overlaps the
// selection. A camera problem only ever closes this window: the recording doesn't depend on it.
let stream, ended = false;
document.body.classList.toggle('rounded', params.get('shape') === 'rounded');
refreshIcons();

function fail(error) {
  if (ended) return;
  ended = true;
  stream?.getTracks().forEach((t) => t.stop());
  still.send('camera:failed', StillMarks.cameraMessage(error));
}

async function begin() {
  if (reloadForMedia()) return;
  if (!navigator.mediaDevices?.getUserMedia) return fail({ name: 'UnsupportedError' });
  const timeout = setTimeout(() => fail({ name: 'TimeoutError' }), StillMarks.CAMERA_TIMEOUT);
  try {
    const camera = await navigator.mediaDevices.getUserMedia({ audio: false, video: { width: { ideal: 720 }, height: { ideal: 720 }, frameRate: { ideal: 30 }, facingMode: 'user' } });
    if (ended) return camera.getTracks().forEach((t) => t.stop()); // Gave up on it before it answered.
    stream = camera;
    stream.getVideoTracks()[0].addEventListener('ended', () => fail({ name: 'EndedError' })); // Unplugged, say.
    const video = $('#video'); video.srcObject = stream; await video.play();
    $('#bubble').classList.add('live');
  } catch (error) { fail(error); }
  finally { clearTimeout(timeout); }
}
begin();
