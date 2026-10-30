#!/bin/bash
# Keep the identity macOS already approved when replacing an installed copy.
set -euo pipefail
source_app="${1:?Usage: install-mac.sh /path/to/Still.app}"
target_app="/Applications/Still.app"
codesign --verify --strict "$source_app"
if [ -d "$target_app" ]; then
    requirement="$(codesign -d -r- "$target_app" 2>&1 | sed -n 's/^designated => //p')"
    if [ -z "$requirement" ] || ! codesign --verify -R="$requirement" "$source_app" >/dev/null 2>&1; then
        echo "This build uses a different signing identity. Install a build signed with the existing release identity to preserve Screen Recording access." >&2
        exit 1
    fi
fi
if pgrep -f '^/Applications/Still.app/Contents/MacOS/Still$' >/dev/null; then
    echo "Quit Still before installing the update." >&2
    exit 1
fi
# Copy next to the old app, then swap, so the bundle is never a mix of two versions.
rm -rf "$target_app.new"; ditto "$source_app" "$target_app.new"
if [ -d "$target_app" ]; then mv "$target_app" "$target_app.old"; fi
mv "$target_app.new" "$target_app" && rm -rf "$target_app.old"
codesign --verify --strict "$target_app"
echo "Installed Still with its existing signing identity."
