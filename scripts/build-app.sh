#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: scripts/build-app.sh [debug|release]
# Release builds are universal and packaged as a zip and a disk image. Set
# SIGN_IDENTITY to a Developer ID Application identity to sign, and NOTARY_PROFILE
# to a notarytool keychain profile to notarize. Without them the app is signed ad hoc.
configuration="${1:-debug}"
arch=()
[[ "$configuration" == release ]] && arch=(--arch arm64 --arch x86_64)

swift build -c "$configuration" ${arch[@]+"${arch[@]}"} --product Outbound
bin="$(swift build -c "$configuration" ${arch[@]+"${arch[@]}"} --show-bin-path)"

app="build/Outbound.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Outbound" "$app/Contents/MacOS/"
cp Configuration/Info.plist "$app/Contents/"
cp Configuration/AppIcon.icns "$app/Contents/Resources/"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi

if [[ "$configuration" == release ]]; then
    zip="build/Outbound.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$app"
        rm "$zip"
        ditto -c -k --keepParent "$app" "$zip"
    fi
    echo "$zip"

    # Disk image with an Applications shortcut, so installing is one drag.
    dmg="build/Outbound.dmg"
    staging="build/dmg"
    rm -rf "$staging" "$dmg"
    mkdir -p "$staging"
    ditto "$app" "$staging/Outbound.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname Outbound -srcfolder "$staging" -format ULFO "$dmg"
    rm -rf "$staging"
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
    fi
    echo "$dmg"
fi
echo "$app"
