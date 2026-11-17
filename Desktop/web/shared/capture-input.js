(function (root) {
  const api = {
    allowsWindowSelection: purpose => purpose === 'screenshot' || purpose === 'record',
    keyAction({ key, code, editingText = false, commandModifier = false, purpose }) {
      if (key === 'Escape') return 'cancel';
      if (code === 'Space' && !editingText && !commandModifier && api.allowsWindowSelection(purpose)) return 'window';
      return 'pass';
    },
    recordingSourceAllowed(selectedWindow, displaySurface) { return !selectedWindow || displaySurface === 'window'; },
    shouldCrop(displaySurface, fullDisplay) { return !fullDisplay && displaySurface !== 'window' && displaySurface !== 'browser'; },
    // Linux can't keep the recording controls out of the video, so when they have to sit over the recorded area
    // every frame is drawn, with their spot blacked out. A window capture never contains them.
    shouldDraw(displaySurface, fullDisplay, masked) { return api.shouldCrop(displaySurface, fullDisplay) || (!!masked && displaySurface !== 'window' && displaySurface !== 'browser'); },
    // The controls' spot, in display pixels, as pixels of the cropped picture (rect scaled to width × height), or
    // null when it is outside the crop. Rounded outwards so no edge of the controls shows.
    maskRect(mask, rect, width, height) {
      if (!mask || !(rect.w > 0) || !(rect.h > 0)) return null;
      const kx = width / rect.w, ky = height / rect.h;
      const x0 = Math.max(mask.x, rect.x), y0 = Math.max(mask.y, rect.y);
      const x1 = Math.min(mask.x + mask.w, rect.x + rect.w), y1 = Math.min(mask.y + mask.h, rect.y + rect.h);
      if (!(x1 > x0 && y1 > y0)) return null;
      const x = Math.floor((x0 - rect.x) * kx), y = Math.floor((y0 - rect.y) * ky);
      return { x, y, w: Math.ceil((x1 - rect.x) * kx) - x, h: Math.ceil((y1 - rect.y) * ky) - y };
    }
  };
  if (typeof module !== 'undefined') module.exports = api;
  else root.StillCaptureInput = api;
})(typeof window !== 'undefined' ? window : globalThis);
