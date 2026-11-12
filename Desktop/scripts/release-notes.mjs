// The notes for one release: that version's section of CHANGELOG.md, without its heading.
// Usage: node release-notes.mjs <CHANGELOG.md> <version>   (prints nothing when the version has no section)
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export function section(markdown, version) {
  const want = `v${String(version).replace(/^v/, '')}`;
  const lines = markdown.split('\n'), out = [];
  let inside = false;
  for (const line of lines) {
    const heading = /^## (v[0-9][^\s]*)/.exec(line);
    if (heading) { if (inside) break; inside = heading[1] === want; continue; }
    if (inside) out.push(line);
  }
  return out.join('\n').trim();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [file, version] = process.argv.slice(2);
  process.stdout.write(section(fs.readFileSync(file, 'utf8'), version));
}
