// Reads the frozen screen's pixels for the capture overlay (the colour under the crosshair, a window's parts) away
// from the page. Read on the page, the whole screen was copied back from the graphics card in one go, just as the
// pointer started to move.
self.onmessage = async ({ data }) => {
  try {
    const canvas = new OffscreenCanvas(data.width, data.height);
    const paint = canvas.getContext('2d', { willReadFrequently: true });
    await Promise.all(data.parts.map(async (part) => {
      const picture = await createImageBitmap(await (await fetch(part.url)).blob());
      paint.drawImage(picture, 0, part.y); picture.close();
    }));
    const pixels = paint.getImageData(0, 0, data.width, data.height);
    self.postMessage({ ok: true, width: pixels.width, height: pixels.height, buffer: pixels.data.buffer }, [pixels.data.buffer]);
  } catch (error) { self.postMessage({ ok: false, error: String(error) }); }
};
