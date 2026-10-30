#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "") bash scripts/build.sh ;;
    --skip-build) ;;
    --help|-h)
        printf 'Usage: bash scripts/package-dmg.sh [--skip-build]\n'
        printf 'Build and package FanCool, or package the existing signed dist/FanCool.app.\n'
        exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    printf 'Only one optional argument is supported.\n' >&2
    exit 2
fi

app="$PWD/dist/FanCool.app"
if [ ! -d "$app" ]; then
    printf 'Missing dist/FanCool.app; run without --skip-build first.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
for notice in LICENSE THIRD_PARTY_NOTICES.md fan-rotor-provenance.md; do
    if [ ! -f "$app/Contents/Resources/$notice" ]; then
        printf 'App is missing %s; rebuild before packaging.\n' "$notice" >&2
        exit 1
    fi
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
case "$version" in
    ""|*[!a-zA-Z0-9._-]*) printf 'Invalid app version.\n' >&2; exit 1 ;;
esac

mkdir -p "$PWD/.build" "$PWD/dist"
staging="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
mkdir "$staging/contents"
# Copy onto fresh inodes. Never modify or re-sign the source app during packaging.
ditto "$app" "$staging/contents/FanCool.app"
ln -s /Applications "$staging/contents/Applications"
name="FanCool-$version.dmg"
hdiutil create -volname "FanCool $version" -fs HFS+ -srcfolder "$staging/contents" \
    -format UDZO -imagekey zlib-level=9 "$staging/$name"
hdiutil verify "$staging/$name"
(
    cd "$staging"
    shasum -a 256 "$name" > "$name.sha256"
)
# Publish only a completed, verified image; an older mounted image is not truncated.
mv "$staging/$name" "$PWD/dist/$name"
mv "$staging/$name.sha256" "$PWD/dist/$name.sha256"
printf '\nDisk image: %s\nChecksum: %s\n' "$PWD/dist/$name" "$PWD/dist/$name.sha256"
printf 'Drag FanCool.app to Applications, eject the image, then launch the installed app.\n'
