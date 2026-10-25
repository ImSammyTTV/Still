#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app_path="${1:-$project_root/../Still.app}"
build_arches=()
if [ "${STILL_UNIVERSAL:-1}" = "1" ]; then build_arches=(--arch arm64 --arch x86_64); fi
swift build -c release "${build_arches[@]}"
binary_dir="$(swift build -c release "${build_arches[@]}" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Still" "$app_path/Contents/MacOS/Still"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Resources/Cloud"
cp Cloud/server.py "$app_path/Contents/Resources/Cloud/"
cp -R Cloud/static "$app_path/Contents/Resources/Cloud/"
if [ -f Cloud/README.md ]; then cp Cloud/README.md "$app_path/Contents/Resources/Cloud/"; fi
mkdir -p "$app_path/Contents/Resources/Documentation"
cp README.md FEATURES.md "$app_path/Contents/Resources/Documentation/"
mkdir -p .build/Still.iconset
swift scripts/make-icon.swift .build/Still.iconset
iconutil -c icns .build/Still.iconset -o "$app_path/Contents/Resources/Still.icns"
sign_identity="${STILL_SIGN_IDENTITY:-}"
if [ -z "$sign_identity" ]; then
    sign_identity="$(security find-identity -v -p codesigning | awk '/Apple Development:/ {print $2; exit}')"
fi
if [ -z "$sign_identity" ]; then sign_identity="-"; fi
codesign --force --sign "$sign_identity" --timestamp=none --identifier local.sam.Still "$app_path"
codesign --verify --strict "$app_path"
printf 'Built %s\n' "$app_path"
