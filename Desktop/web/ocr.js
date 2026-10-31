// Text recognition with the bundled Tesseract engine (WebAssembly), shared by the editor and the OCR capture page.
window.StillOCR = {
  worker: null,
  async start() {
    if (!this.worker) {
      const base = new URL('vendor/ocr/', location.href).href;
      this.worker = await Tesseract.createWorker('eng', 1, { workerPath: `${base}worker.min.js`, corePath: base, langPath: base, gzip: true, cacheMethod: 'none', workerBlobURL: false });
    }
    return this.worker;
  },
  async recognize(source) {
    const { data } = await (await this.start()).recognize(source);
    return data.text || '';
  },
  // The text as lines of words, each with its box in the picture's pixels.
  async lines(source) {
    const { data } = await (await this.start()).recognize(source, {}, { blocks: true });
    const lines = [];
    for (const block of data.blocks || []) for (const paragraph of block.paragraphs || []) for (const line of paragraph.lines || []) {
      const words = (line.words || []).filter((w) => w.text && w.text.trim()).map((w) => ({ text: w.text.trim(), box: w.bbox }));
      if (words.length) lines.push(words);
    }
    return lines;
  }
};
