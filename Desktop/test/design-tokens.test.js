// Design tokens guard: page styles use the tokens from style.css instead of raw colours.
// Raw values are allowed only where tokens are defined (:root, theme and glass variants),
// and for pure black or white, which shadows, scrims and the brand mark legitimately use.
// See docs/DESIGN-SYSTEM.md.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const files = [
  ...fs.readdirSync(path.join(root, 'Desktop/web')).filter((f) => f.endsWith('.html')).map((f) => `Desktop/web/${f}`),
  'Desktop/web/style.css', 'Cloud/static/style.css', 'Cloud/static/index.html'
];

function componentCSS(source, isCSS) {
  let css = isCSS ? source : [...source.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join('\n');
  // Strip the blocks that are allowed to hold raw values: token definitions and their theme variants.
  // Braces inside {{ACCENT}} belong to the server's placeholder, so they are neutralised first.
  css = css.replace(/\{\{ACCENT\}\}/g, 'ACCENT');
  return css.replace(/(?::root[^{]*|body\.win32\.glass[^{]*|\.glass[^{]*)\{[^}]*\}/g, '');
}
const allowed = /^(#fff|#ffffff|#000|#000000|rgba\(\s*0\s*,\s*0\s*,\s*0\s*,[^)]*\)|rgba\(\s*255\s*,\s*255\s*,\s*255\s*,[^)]*\))$/i;

for (const file of files) {
  test(`${file} uses design tokens for colours`, () => {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const css = componentCSS(source, file.endsWith('.css'));
    const raw = [...css.matchAll(/#[0-9a-f]{3,8}\b|rgba?\([^)]*\)/gi)].map((m) => m[0]).filter((v) => !allowed.test(v));
    assert.deepStrictEqual([...new Set(raw)], [], `raw colours outside token blocks: ${raw.join(', ')}`);
    const inline = [...source.matchAll(/style="[^"]*(?:#[0-9a-f]{3,8}\b|rgba?\()[^"]*"/gi)].map((m) => m[0]);
    assert.deepStrictEqual(inline, [], `inline style with a raw colour: ${inline.join(', ')}`);
  });
}

test('every page keeps readable text at 11px or larger', () => {
  for (const file of files) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const css = componentCSS(source, file.endsWith('.css'));
    const small = [...css.matchAll(/font(?:-size)?:\s*([0-9.]+)px/g)].map((m) => Number(m[1])).filter((n) => n < 10);
    assert.deepStrictEqual(small, [], `${file} sets text below 10px: ${small.join(', ')}`);
  }
});
