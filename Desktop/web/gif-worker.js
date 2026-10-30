// Builds a GIF away from the page, one message at a time, so the window stays responsive.
// Each message gets exactly one reply; the page waits for it before sending the next frame.
importScripts('shared/gif.js');
let encoder;

self.onmessage = ({ data }) => {
  try {
    if (data.type === 'start') { encoder = new StillGIF.Encoder(data.width, data.height); self.postMessage({ ok: true }); }
    else if (data.type === 'sample') { encoder.addSample(data.rgba); self.postMessage({ ok: true }); }
    else if (data.type === 'frame') { encoder.addFrame(data.rgba, data.delay); self.postMessage({ ok: true }); }
    else if (data.type === 'finish') { const bytes = encoder.finish(); self.postMessage({ ok: true, bytes }, [bytes.buffer]); }
  } catch (error) { self.postMessage({ ok: false, error: error.message || String(error) }); }
};
