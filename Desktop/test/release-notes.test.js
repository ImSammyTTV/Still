const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('a release gets its own section of the changelog, and nothing else', async () => {
  const { section } = await import('../scripts/release-notes.mjs');
  const log = '# Changelog\n\nIntro.\n\n## v1.2.3 — 2026-01-02\n\n- New thing\n- Fixed thing\n\n## v1.2.2 — 2026-01-01\n\n- Old thing\n';
  assert.equal(section(log, 'v1.2.3'), '- New thing\n- Fixed thing');
  assert.equal(section(log, '1.2.2'), '- Old thing');
  assert.equal(section(log, 'v9.9.9'), '');
  const { versions } = await import('../scripts/release-notes.mjs');
  assert.deepEqual(versions(log), ['v1.2.3', 'v1.2.2']);
});

test('the version being released has a changelog entry', async () => {
  const { section } = await import('../scripts/release-notes.mjs');
  const root = path.join(__dirname, '..', '..');
  const version = JSON.parse(fs.readFileSync(path.join(root, 'Desktop/package.json'), 'utf8')).version;
  assert.ok(section(fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8'), version), `CHANGELOG.md needs a "## v${version}" section`);
});
