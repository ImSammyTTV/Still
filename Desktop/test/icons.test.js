const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Every icon a page names must be in web/vendor/icons.js, the trimmed set (rebuild it with
// `node scripts/build-icons.mjs`). Names come from data-lucide attributes and icon('name') calls.
test('every icon the pages use is in the trimmed icon set', () => {
  global.self = {};
  require('../web/vendor/icons.js');
  const { icons } = global.self.lucide;
  const web = path.join(__dirname, '..', 'web');
  const missing = [];
  for (const file of fs.readdirSync(web).filter((f) => /\.(html|js)$/.test(f))) {
    const text = fs.readFileSync(path.join(web, file), 'utf8');
    for (const m of text.matchAll(/data-lucide="([a-z0-9-]+)"|icon\('([a-z0-9-]+)'/g)) {
      const name = m[1] || m[2];
      if (!icons[name]) missing.push(`${file}: ${name}`);
    }
  }
  assert.deepEqual(missing, []);
});
