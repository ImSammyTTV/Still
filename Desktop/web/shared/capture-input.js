(function (root) {
  const api = {
    allowsWindowSelection: purpose => purpose === 'screenshot' || purpose === 'record',
    keyAction({ key, code, editingText = false, commandModifier = false, purpose }) {
      if (key === 'Escape') return 'cancel';
      if (code === 'Space' && !editingText && !commandModifier && api.allowsWindowSelection(purpose)) return 'window';
      return 'pass';
    },
    recordingSourceAllowed(selectedWindow, displaySurface) { return !selectedWindow || displaySurface === 'window'; },
    shouldCrop(displaySurface, fullDisplay) { return !fullDisplay && displaySurface !== 'window' && displaySurface !== 'browser'; }
  };
  if (typeof module !== 'undefined') module.exports = api;
  else root.StillCaptureInput = api;
})(typeof window !== 'undefined' ? window : globalThis);
