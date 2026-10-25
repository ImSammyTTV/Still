// Text recognition with the bundled Tesseract engine (WebAssembly), shared by the editor and the OCR capture page.
window.StillOCR = {
  worker: null,
  async recognize(source) {
    if (!this.worker) {
      const base = new URL('vendor/ocr/', location.href).href;
      this.worker = await Tesseract.createWorker('eng', 1, { workerPath: `${base}worker.min.js`, corePath: base, langPath: base, gzip: true, cacheMethod: 'none', workerBlobURL: false });
    }
    const { data } = await this.worker.recognize(source);
    return data.text || '';
  }
};
