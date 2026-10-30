#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
export SWIFTPM_CUSTOM_BIN_DIR="/Library/Developer/CommandLineTools/usr/bin"
identity="${CODE_SIGN_IDENTITY:--}"
build_flags=(-c release --disable-sandbox -debug-info-format none --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
swift build "${build_flags[@]}"
bin_path="$(swift build "${build_flags[@]}" --show-bin-path)"
mkdir -p "$PWD/dist" "$PWD/.build/previous-builds"
# Never truncate or re-sign an installed executable: it may be memory-mapped
# by a running process. Build and sign on fresh inodes, then swap the bundles.
staging="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rmdir "$staging" 2>/dev/null || true' EXIT
app="$staging/FanCool.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/FanCool" "$app/Contents/MacOS/FanCool"
cp "$bin_path/FanCoolHelper" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/fan-rotor.png "$app/Contents/Resources/"
# Command-line previews use the same asset as the packaged app.
cp Resources/fan-rotor.png "$bin_path/"
swift scripts/make-icon.swift "$PWD/.build/FanCool.iconset" "$PWD/Resources/fan-rotor.png"
iconutil -c icns "$PWD/.build/FanCool.iconset" -o "$app/Contents/Resources/FanCool.icns"
codesign --force --sign "$identity" --identifier local.minifan.helper --options runtime --timestamp=none "$app/Contents/MacOS/FanCoolHelper"
codesign --force --sign "$identity" --identifier local.minifan.app --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/FanCool.zip"
backup="$PWD/.build/previous-builds/FanCool-$(date +%Y%m%d-%H%M%S)-$RANDOM.app"
swift scripts/publish-app.swift "$app" "$PWD/dist/FanCool.app" "$backup"
mv "$staging/FanCool.zip" "$PWD/dist/FanCool.zip"
printf '\nBuilt: %s\nArchive: %s\n' "$PWD/dist/FanCool.app" "$PWD/dist/FanCool.zip"
if [ "$identity" = "-" ]; then
    printf 'Local build: authorize or update the FanCool helper in the app using macOS administrator authentication.\n'
fi
