const { clipboard, ClipboardItem } = require('electron');
const { pathToFileURL } = require('url');

// Electron 45 replaced the synchronous clipboard with the async, web-style API. These helpers keep
// every copy path in one place.
const pngBlob = (image) => new Blob([Buffer.isBuffer(image) ? image : image.toPNG()], { type: 'image/png' });

async function copyImage(image) {
  await clipboard.write([new ClipboardItem({ 'image/png': pngBlob(image) })]);
}

async function copyText(text) { await clipboard.writeText(text); }

// Copies a file (for recordings) so it can be pasted into Explorer, a file manager or a chat app.
async function copyFile(file) {
  const native = process.platform === 'win32'
    ? { 'electron application/osclipboard;format="FileNameW"': new Blob([Buffer.from(`${file}\0`, 'utf16le')]) }
    : { 'text/uri-list': new Blob([pathToFileURL(file).href + '\r\n'], { type: 'text/uri-list' }) };
  try { await clipboard.write([new ClipboardItem({ ...native, 'text/plain': new Blob([file], { type: 'text/plain' }) })]); }
  catch { await clipboard.writeText(file); }
}

async function hasImage() {
  const items = await clipboard.read();
  return items.some((item) => item.types.some((type) => type.startsWith('image/')));
}

module.exports = { copyImage, copyText, copyFile, hasImage };
