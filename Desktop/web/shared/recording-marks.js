// Pure logic for the recording overlays, shared by the pages and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillRecordingMarks = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const KEY_LIMIT = 6; // Fast typing replaces the oldest keys rather than filling the screen.
  const KEY_LIFE = 1800;
  const CAMERA_TIMEOUT = 30000;

  // What's on screen after a key arrives (or, with no text, after time passes). Nothing else remembers keys.
  const visibleKeys = (shown, text, now) => {
    const alive = shown.filter((key) => now - key.at < KEY_LIFE);
    return (text ? [...alive, { text, at: now }] : alive).slice(-KEY_LIMIT);
  };

  // The camera is optional, so every failure ends with the recording carrying on.
  const cameraMessage = (error) => {
    const name = (error && error.name) || '';
    const reason = {
      NotAllowedError: 'Still isn’t allowed to use the camera. Check your system’s camera privacy settings.',
      SecurityError: 'Still isn’t allowed to use the camera. Check your system’s camera privacy settings.',
      NotFoundError: 'No camera was found.',
      OverconstrainedError: 'No camera was found.',
      NotReadableError: 'The camera is busy or another app is using it.',
      AbortError: 'The camera is busy or another app is using it.',
      TimeoutError: 'The camera didn’t start in time.',
      UnsupportedError: 'This system’s web engine can’t show the camera.',
      EndedError: 'The camera stopped working.'
    }[name] || 'The camera could not be started.';
    return `${reason} The recording continues without it.`;
  };

  return { KEY_LIFE, CAMERA_TIMEOUT, visibleKeys, cameraMessage };
});
