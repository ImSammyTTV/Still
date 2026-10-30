#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app_path="${1:-$project_root/../Still.app}"
build_arches=()
if [ "${STILL_UNIVERSAL:-1}" = "1" ]; then build_arches=(--arch arm64 --arch x86_64); fi
swift build -c release ${build_arches[@]+"${build_arches[@]}"}
binary_dir="$(swift build -c release ${build_arches[@]+"${build_arches[@]}"} --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Still" "$app_path/Contents/MacOS/Still"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Resources/Cloud"
cp Cloud/server.py "$app_path/Contents/Resources/Cloud/"
cp -R Cloud/static "$app_path/Contents/Resources/Cloud/"
if [ -f Cloud/README.md ]; then cp Cloud/README.md "$app_path/Contents/Resources/Cloud/"; fi
mkdir -p "$app_path/Contents/Resources/Documentation"
cp README.md FEATURES.md "$app_path/Contents/Resources/Documentation/"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$app_path/Contents/Resources/"
mkdir -p .build/Still.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out .build/Still.iconset/icon_${size}x${size}.png >/dev/null
  sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out .build/Still.iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns .build/Still.iconset -o "$app_path/Contents/Resources/Still.icns"
sign_identity="${STILL_SIGN_IDENTITY:-}"
if [ -z "$sign_identity" ]; then
    sign_identity="$(security find-identity -v -p codesigning | awk '/Apple Development:/ {print $2; exit}')"
fi
if [ -z "$sign_identity" ]; then
    if [ "${STILL_REQUIRE_SIGNING:-0}" = "1" ]; then echo "No signing identity found" >&2; exit 1; fi
    sign_identity="-"
fi
# Hardened Runtime stops other code from injecting itself into Still and borrowing its Screen Recording,
# camera and microphone access. The entitlements re-allow the camera and microphone.
codesign --force --sign "$sign_identity" --timestamp=none --options runtime --entitlements Resources/Still.entitlements --identifier local.sam.Still "$app_path"
codesign --verify --strict "$app_path"
printf 'Built %s\n' "$app_path"
