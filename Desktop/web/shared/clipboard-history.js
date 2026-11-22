// Clipboard History's picker: what each entry is called, what's shown under it, and which entries a search finds.
// Titles follow the Mac app's ClipItem.title, so an entry reads the same on every platform. Remembering, merging
// copies of the same thing and keeping the newest are done by the app (src-tauri/src/clipboard.rs).
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillClipboard = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  // Settings → Clipboard → Remember, as on the Mac.
  const LIMITS = [25, 50, 100, 200];
  // Number keys pick the newest ten: 1–9, then 0.
  const NUMBERED = 10;

  const NEWLINES = /\r\n|[\n\r\u000b\u000c\u0085\u2028\u2029]/;
  const baseName = (path) => String(path || '').split(/[\\/]/).filter(Boolean).pop() || String(path || '');

  // The first line of a text, cut to 60 characters; a picture's size; the first file's name and how many more.
  function title(item) {
    if (!item) return '';
    if (item.kind === 'image') return `Image ${item.width || 0} × ${item.height || 0}`;
    if (item.kind === 'files') {
      const names = (item.files || []).map(baseName);
      return names.length > 1 ? `${names[0]} + ${names.length - 1} more` : (names[0] || 'Files');
    }
    // The first line that isn't empty, as the Mac's split by line skips empty ones.
    const line = (String(item.text || '').split(NEWLINES).find((part) => part.length) || '').trim();
    const chars = [...line];
    if (!chars.length) return '(blank text)';
    return chars.length > 60 ? `${chars.slice(0, 57).join('')}…` : line;
  }

  // How long ago, in a few words.
  function age(date, now = Date.now()) {
    const seconds = Math.max(0, Math.round((now - (Number(date) || 0)) / 1000));
    if (seconds < 60) return 'Just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} min ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} hr ago`;
    const days = Math.floor(hours / 24);
    return days === 1 ? 'Yesterday' : `${days} days ago`;
  }

  // The small line under the title: what kind of copy it is and when it was made.
  function detail(item, now = Date.now()) {
    if (!item) return '';
    let kind = 'Text';
    if (item.kind === 'image') kind = 'Image';
    else if (item.kind === 'files') { const n = (item.files || []).length; kind = n === 1 ? 'File' : `${n} files`; }
    return `${kind} · ${age(item.date, now)}`;
  }

  // Every word of the search appears in the entry's text, its file paths or (for a picture) "image" and its size.
  function matches(item, query) {
    const words = String(query || '').toLocaleLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return true;
    const text = [item.text || '', ...(item.files || []), item.kind === 'image' ? `image ${item.width}×${item.height} ${item.width} × ${item.height}` : '']
      .join('\n').toLocaleLowerCase();
    return words.every((word) => text.includes(word));
  }
  const filter = (items, query) => (items || []).filter((item) => matches(item, query));

  // The entry a number key picks (0-based), or -1: 1 is the newest, 0 the tenth.
  function numberIndex(key) {
    if (!/^[0-9]$/.test(String(key))) return -1;
    const n = Number(key);
    return n === 0 ? NUMBERED - 1 : n - 1;
  }
  // The key shown beside an entry, or '' past the tenth.
  const numberKey = (index) => (index < 0 || index >= NUMBERED ? '' : String((index + 1) % 10));

  // Moving the highlight with the arrow keys, Page Up/Down, Home and End: stays within the list.
  function step(index, delta, count) {
    if (count <= 0) return -1;
    return Math.min(count - 1, Math.max(0, (index < 0 ? (delta > 0 ? -1 : count) : index) + delta));
  }

  return { LIMITS, NUMBERED, title, age, detail, matches, filter, numberIndex, numberKey, step, baseName };
});
