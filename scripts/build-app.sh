#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: scripts/build-app.sh [debug|release]
# Release builds are for Apple silicon, whose GPUs the renderer needs, and are
# packaged as a zip and a disk image. Set
# SIGN_IDENTITY to a Developer ID Application identity to sign, and NOTARY_PROFILE
# to a notarytool keychain profile to notarize. Without them the app is signed ad hoc.
configuration="${1:-debug}"
if [[ -n "${SIGN_IDENTITY:-}" ]] && grep -q 'POLAR_ORGANIZATION_ID\|POLAR_CHECKOUT_LINK' Sources/Outbound/Licensing/Store.swift; then
    echo "Set the Polar organization ID and checkout link in Sources/Outbound/Licensing/Store.swift first." >&2
    exit 1
fi
arch=()
[[ "$configuration" == release ]] && arch=(--arch arm64)

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

    # Disk image with an Applications shortcut, so installing is one drag. Finder lays
    # out the window on a writable copy in a temporary folder, which is then compressed.
    dmg="build/Outbound.dmg"
    if [[ -e /Volumes/Outbound ]]; then
        echo "Eject the mounted Outbound disk image first." >&2
        exit 1
    fi
    work="$(mktemp -d /tmp/outbound.XXXXXX)"
    staging="$work/Outbound"
    writable="$work/Outbound.dmg"
    rm -f "$dmg"
    mkdir -p "$staging/.background"
    ditto "$app" "$staging/Outbound.app"
    ln -s /Applications "$staging/Applications"
    tiffutil -cathidpicheck Configuration/DiskImage.png Configuration/DiskImage@2x.png \
        -out "$staging/.background/Background.tiff" 2>/dev/null
    hdiutil create -quiet -volname Outbound -srcfolder "$staging" -fs HFS+ -format UDRW "$writable"
    mount="$(hdiutil attach -noautoopen "$writable" 2>/dev/null | awk -F '\t' '/\/Volumes\// { print $NF }')"
    if ! osascript - "$mount" <<'APPLESCRIPT'
on run {mountPath}
    tell application "Finder"
        set theDisk to (POSIX file mountPath as alias)
        open theDisk
        delay 1
        set win to front Finder window
        set current view of win to icon view
        set toolbar visible of win to false
        set statusbar visible of win to false
        set bounds of win to {200, 120, 800, 488}
        set viewOptions to icon view options of win
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to (POSIX file (mountPath & "/.background/Background.tiff") as alias)
        set position of item "Outbound.app" of theDisk to {170, 160}
        set position of item "Applications" of theDisk to {430, 160}
        update theDisk without registering applications
        delay 1
        close win
    end tell
end run
APPLESCRIPT
    then
        hdiutil detach -quiet "$mount"
        exit 1
    fi
    sleep 2
    # Finder drops a custom volume icon while it lays out the window, so it goes in last.
    cp Configuration/AppIcon.icns "$mount/.VolumeIcon.icns"
    SetFile -a C "$mount" 2>/dev/null || true
    rm -rf "$mount/.fseventsd"
    sync
    hdiutil detach -quiet "$mount"
    hdiutil convert -quiet "$writable" -format ULFO -o "$dmg"
    rm -rf "$work"
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
