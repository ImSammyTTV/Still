// Builds the updater feed (latest.json) from the signed bundles in a release folder.
// Usage: node latest-json.mjs <folder> <version> <owner/repo>
import fs from 'node:fs';
import path from 'node:path';

const [dir, version, repo] = process.argv.slice(2);
const tag = `v${version.replace(/^v/, '')}`;
const rules = [
  [/_x64-setup\.exe$/, ['windows-x86_64', 'windows-x86_64-nsis']],
  [/_arm64-setup\.exe$/, ['windows-aarch64', 'windows-aarch64-nsis']],
  [/_amd64\.AppImage$/, ['linux-x86_64', 'linux-x86_64-appimage']],
  [/_aarch64\.AppImage$/, ['linux-aarch64', 'linux-aarch64-appimage']],
  [/_amd64\.deb$/, ['linux-x86_64-deb']],
  [/_arm64\.deb$/, ['linux-aarch64-deb']],
  [/\.x86_64\.rpm$/, ['linux-x86_64-rpm']],
  [/\.aarch64\.rpm$/, ['linux-aarch64-rpm']]
];
const platforms = {};
for (const file of fs.readdirSync(dir)) {
  if (!file.endsWith('.sig')) continue;
  const bundle = file.slice(0, -4);
  const rule = rules.find(([re]) => re.test(bundle));
  if (!rule) continue;
  const entry = { signature: fs.readFileSync(path.join(dir, file), 'utf8').trim(), url: `https://github.com/${repo}/releases/download/${tag}/${encodeURIComponent(bundle)}` };
  for (const key of rule[1]) platforms[key] = entry;
}
// Every platform must be present, or apps on the missing ones would be told there's no update (or worse).
const missing = rules.flatMap(([, keys]) => keys).filter(key => !platforms[key]);
if (missing.length) { console.error(`Missing update bundles for: ${missing.join(', ')}`); process.exit(1); }
const feed = { version: version.replace(/^v/, ''), notes: `See https://github.com/${repo}/releases/tag/${tag}`, pub_date: new Date().toISOString(), platforms };
fs.writeFileSync(path.join(dir, 'latest.json'), JSON.stringify(feed, null, 2));
console.log(Object.keys(platforms).join('\n'));
