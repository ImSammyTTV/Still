#!/bin/sh
# Installs or removes Still.app from the latest GitHub release.
set -eu
repo="ImSammyTTV/Still"
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
api="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")"
zip_url="$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*mac-universal\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
sums_url="$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS[^"]*"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$zip_url" ] || { echo "No Mac download found in the latest release."; exit 1; }

echo "Downloading $(basename "$zip_url")…"
curl -fsSL "$zip_url" -o "$work/Still.zip"
if [ -n "$sums_url" ]; then
  curl -fsSL "$sums_url" -o "$work/SHA256SUMS"
  expected="$(grep "$(basename "$zip_url")" "$work/SHA256SUMS" | awk '{print $1}')"
  actual="$(shasum -a 256 "$work/Still.zip" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || { echo "Checksum mismatch. Nothing was installed."; exit 1; }
fi

ditto -x -k "$work/Still.zip" "$work/unzipped"
osascript -e 'quit app "Still"' >/dev/null 2>&1 || true
rm -rf "$app"
ditto "$work/unzipped/Still.app" "$app"
echo "Installed Still in Applications."
open "$app"
