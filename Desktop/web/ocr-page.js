// Hidden page: recognises the captured image (or a test phrase) and reports back.
(async () => {
  const params = window.__STILL_PARAMS__ || {};
  let source;
  if (params.probe) {
    const c = document.createElement('canvas'); c.width = 700; c.height = 140;
    const t = c.getContext('2d'); t.fillStyle = '#fff'; t.fillRect(0, 0, 700, 140); t.fillStyle = '#000'; t.font = '56px Arial'; t.fillText('Still OCR works', 30, 90);
    source = c.toDataURL();
  } else source = still.fileUrl(params.file);
  try { still.invoke('ocr:result', await StillOCR.recognize(source), null); }
  catch (error) { still.invoke('ocr:result', '', String(error && error.message || error)); }
})();
