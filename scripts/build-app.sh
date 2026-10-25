#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: scripts/build-app.sh [debug|release]
# Release builds are for Apple silicon, whose GPUs the renderer needs, and are
# packaged as a zip and a disk image. Set SIGN_IDENTITY to a Developer ID
# Application identity to sign, and NOTARY_PROFILE to a notarytool keychain
# profile to notarize. Without them the app is signed ad hoc.
configuration="${1:-debug}"
arch=()
[[ "$configuration" == release ]] && arch=(--arch arm64)

swift build -c "$configuration" ${arch[@]+"${arch[@]}"} --product Outbound
bin="$(swift build -c "$configuration" ${arch[@]+"${arch[@]}"} --show-bin-path)"

app="build/Outbound.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Outbound" "$app/Contents/MacOS/"
cp Configuration/Info.plist "$app/Contents/"
# A development build answers outbound-dev:// links, so it never takes links meant for an installed release.
[[ "$configuration" == debug ]] && plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string outbound-dev \
    "$app/Contents/Info.plist"
cp Configuration/AppIcon.icns "$app/Contents/Resources/"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done

# Sparkle, for updates, lives in Contents/Frameworks. Its XPC services are only for sandboxed apps.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
# The build points the binary at its own folders by absolute path; a shipped app looks only inside itself.
binary="$app/Contents/MacOS/Outbound"
otool -l "$binary" | awk '/LC_RPATH/ { getline; getline; print $2 }' | while read -r path; do
    if [[ "$path" == /* ]]; then install_name_tool -delete_rpath "$path" "$binary"; fi
done
install_name_tool -add_rpath @executable_path/../Frameworks "$binary"

# Sign from the inside out, as notarization requires.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    sign=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
    sign=(codesign --force --sign -)
fi
"${sign[@]}" "$sparkle/Versions/B/Autoupdate"
"${sign[@]}" "$sparkle/Versions/B/Updater.app"
"${sign[@]}" "$sparkle"
"${sign[@]}" "$app"

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
        set bounds of win to {200, 120, 800, 520}
        set viewOptions to icon view options of win
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to (POSIX file (mountPath & "/.background/Background.tiff") as alias)
        set position of item "Outbound.app" of theDisk to {170, 196}
        set position of item "Applications" of theDisk to {430, 196}
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
