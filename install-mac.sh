#!/bin/sh
# Installs or removes Still.app from the latest GitHub release.
set -eu
repo="ImSammyTTV/Still"
# Releases are signed with the project's own certificate; anything else is refused.
requirement='identifier "local.sam.Still" and certificate root = H"1ab04d5c40093d821eb23c1655fe959439cc467b"'
fetch() { curl --proto '=https' --tlsv1.2 -fsSL "$@"; }
app="/Applications/Still.app"

if [ "${1:-}" = "--uninstall" ]; then
  osascript -e 'quit app "Still"' >/dev/null 2>&1 || true
  rm -rf "$app"
  echo "Still was removed. Your captures are still in ~/Library/Application Support/Still."
  exit 0
fi

[ "$(uname)" = "Darwin" ] || { echo "This installer is for macOS."; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Finding the latest Still release…"
api="$(fetch "https://api.github.com/repos/$repo/releases/latest")"
zip_url="$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*mac-universal\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
sums_url="$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS[^"]*"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$zip_url" ] || { echo "No Mac download found in the latest release."; exit 1; }
[ -n "$sums_url" ] || { echo "The latest release has no checksums, so it can't be verified. Nothing was installed."; exit 1; }

echo "Downloading $(basename "$zip_url")…"
fetch "$zip_url" -o "$work/Still.zip"
fetch "$sums_url" -o "$work/SHA256SUMS"
expected="$(grep " $(basename "$zip_url")\$" "$work/SHA256SUMS" | awk '{print $1}')"
actual="$(shasum -a 256 "$work/Still.zip" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "Checksum mismatch. Nothing was installed."; exit 1; }

ditto -x -k "$work/Still.zip" "$work/unzipped"
codesign --verify --deep --strict -R="$requirement" "$work/unzipped/Still.app" 2>/dev/null \
  || { echo "This download isn't signed by the Still project. Nothing was installed."; exit 1; }
osascript -e 'quit app "Still"' >/dev/null 2>&1 || true
# Copy first, then swap, so a failure never leaves you without Still.
rm -rf "$app.new"; ditto "$work/unzipped/Still.app" "$app.new"
if [ -d "$app" ]; then mv "$app" "$app.old"; fi
mv "$app.new" "$app" && rm -rf "$app.old"
echo "Installed Still in Applications."
open "$app"
