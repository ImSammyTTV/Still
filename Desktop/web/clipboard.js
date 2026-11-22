// Clipboard History's picker: opens by the pointer with the shortcut or from the tray menu. Type to search, arrows and
// Enter (or a click) to choose, 1–9 and 0 for the newest ten, Delete to forget one, Esc to close.
let state = { enabled: true, pasteAutomatically: false, canPaste: false, items: [] };
let shown = [], active = 0, choosing = false;
const search = $('#search'), list = $('#list');

// Each entry's title and line are worked out once per load, not on every key typed.
const prepare = (items) => items.map((item) => ({ ...item, label: StillClipboard.title(item), line: StillClipboard.detail(item) }));
const numbered = () => !search.value.trim();

function render() {
  shown = StillClipboard.filter(state.items, search.value);
  active = Math.min(Math.max(active, 0), shown.length - 1);
  if (!shown.length) {
    const message = !state.items.length
      ? (state.enabled ? ['clock', 'Nothing copied yet', 'Text, pictures and files you copy will appear here.'] : ['eye-off', 'Clipboard History is off', 'Turn it on in Settings → Clipboard.'])
      : ['search', 'No matches', 'Try other words.'];
    list.replaceChildren(el('div', { class: 'empty' }, [el('span', { html: icon(message[0]) }), el('b', {}, message[1]), el('span', {}, message[2])]));
  } else {
    list.replaceChildren(...shown.map((item, index) => {
      const glyph = item.kind === 'image' && item.thumb
        ? el('img', { src: still.fileUrl(item.thumb), alt: '', loading: 'lazy', onerror: (e) => { e.target.replaceWith(el('span', { html: icon('image') })); refreshIcons(); } })
        : el('span', { html: icon(item.kind === 'files' ? 'file' : item.kind === 'image' ? 'image' : 'text') });
      const key = numbered() ? StillClipboard.numberKey(index) : '';
      return el('div', { class: `entry${index === active ? ' active' : ''}`, role: 'option', 'aria-selected': index === active ? 'true' : 'false', title: item.kind === 'files' ? (item.files || []).join('\n') : '',
        onmousemove: () => { if (active !== index) { active = index; highlight(); } },
        onclick: () => choose(index) }, [
        el('div', { class: 'glyph' }, glyph),
        el('div', { class: 'words' }, [el('div', { class: 'name' }, item.label), el('div', { class: 'detail' }, item.line)]),
        key ? el('kbd', {}, key) : el('span')
      ]);
    }));
  }
  refreshIcons();
  highlight();
}

function highlight() {
  [...list.children].forEach((row, index) => {
    const on = index === active;
    row.classList.toggle('active', on);
    if (row.getAttribute('role') === 'option') row.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  list.children[active]?.scrollIntoView?.({ block: 'nearest' });
}

function showKeys() {
  const paste = state.pasteAutomatically && state.canPaste;
  $('#keys').replaceChildren(...[`↑↓ move`, `Enter ${paste ? 'paste' : 'copy'}`, '1–9, 0 pick', 'Del remove', 'Esc close'].map((text) => el('span', {}, text)));
}

async function load() {
  try { state = await still.invoke('clipboard:list'); } catch (error) { toast(explain(error)); }
  state.items = prepare(state.items || []);
  showKeys();
  render();
}

// Puts the entry back on the clipboard. With "Paste automatically" on, Still closes this and pastes it; otherwise
// (or where pasting isn't possible) it's ready for Ctrl+V.
async function choose(index) {
  const item = shown[index];
  if (!item || choosing) return;
  choosing = true;
  try {
    const pasted = await still.invoke('clipboard:choose', item.id);
    if (!pasted && state.pasteAutomatically && !state.canPaste) {
      toast('Copied. Press Ctrl+V to paste it.');
      setTimeout(() => still.send('window:close'), 1400);
      return;
    }
    still.send('window:close');
  } catch (error) {
    choosing = false;
    toast(explain(error));
  }
}

async function remove(index) {
  const item = shown[index];
  if (!item) return;
  await still.invoke('clipboard:remove', item.id).catch((error) => toast(explain(error)));
}

addEventListener('keydown', (e) => {
  const page = Math.max(1, Math.floor(list.clientHeight / 46));
  const moves = { ArrowDown: 1, ArrowUp: -1, PageDown: page, PageUp: -page };
  if (e.key === 'Escape') { e.preventDefault(); still.send('window:close'); return; }
  if (e.key in moves) { e.preventDefault(); active = StillClipboard.step(active, moves[e.key], shown.length); highlight(); return; }
  if ((e.key === 'Home' || e.key === 'End') && !search.value) { e.preventDefault(); active = e.key === 'Home' ? 0 : shown.length - 1; highlight(); return; }
  if (e.key === 'Enter') { e.preventDefault(); choose(active); return; }
  // Delete forgets the highlighted entry; while typing a search it edits the search, unless the caret is at its end.
  if (e.key === 'Delete' && (!search.value || search.selectionStart === search.value.length)) { e.preventDefault(); remove(active); return; }
  // Number keys pick until a search is typed; then they're part of the search.
  const index = StillClipboard.numberIndex(e.key);
  if (index >= 0 && numbered() && !e.ctrlKey && !e.altKey && !e.metaKey) { e.preventDefault(); choose(index); return; }
  // Typing anywhere goes to the search.
  if (document.activeElement !== search && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) search.focus();
});
search.addEventListener('input', () => { active = 0; render(); });
$('#settings').addEventListener('click', () => { still.send('open:settings', 'Clipboard'); still.send('window:close'); });
// Like a menu, it goes away when you click elsewhere.
addEventListener('blur', () => { if (!choosing) still.send('window:close'); });
still.on('clipboard:changed', load);

(async () => {
  await applyTheme();
  await load();
  search.focus();
})();
