#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: scripts/build-app.sh [debug|release|appstore]
# Release builds are for Apple silicon, whose GPUs the renderer needs, and are
# packaged as a zip and a disk image. Set SIGN_IDENTITY to a Developer ID
# Application identity to sign, and NOTARY_PROFILE to a notarytool keychain
# profile to notarize. Without them the app is signed ad hoc.
#
# appstore builds the Mac App Store edition into build/appstore: sandboxed, with no
# Sparkle and no license store, packaged as an installer for App Store Connect.
# Set SIGN_IDENTITY to an Apple Distribution identity, INSTALLER_IDENTITY to a Mac
# Installer Distribution one and APPSTORE_PROFILE to its provisioning profile, and
# APPSTORE_BUILD to give a re-upload of the same version a build number of its own.
# Without them it is signed ad hoc to run here, under a bundle ID of its own, so
# its sandbox container never belongs to the real app.
edition="${1:-debug}"
configuration="$edition"
options=()
case "$edition" in
    release) options=(--arch arm64) ;;
    appstore)
        configuration=release
        export OUTBOUND_APPSTORE=1
        # A build folder of its own, and no cached manifest, so nothing of the Sparkle build comes along.
        options=(--arch arm64 --scratch-path .build/appstore --manifest-cache none) ;;
esac

swift build -c "$configuration" ${options[@]+"${options[@]}"} --product Outbound
bin="$(swift build -c "$configuration" ${options[@]+"${options[@]}"} --show-bin-path)"

app="build/Outbound.app"
[[ "$edition" == appstore ]] && app="build/appstore/Outbound.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Outbound" "$app/Contents/MacOS/"
cp Configuration/Info.plist "$app/Contents/"
# A development build answers outbound-dev:// links, so it never takes links meant for an installed release.
[[ "$configuration" == debug ]] && plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string outbound-dev \
    "$app/Contents/Info.plist"
cp Configuration/AppIcon.icns "$app/Contents/Resources/"
# The interface in each language Outbound speaks, checked, then compiled into the app's own Resources, where AppKit,
# SwiftUI and Sparkle all look for it. scripts/strings.sh brings the catalog up to date with the code.
python3 scripts/check-strings.py
xcrun xcstringstool compile Configuration/Localizable.xcstrings --output-directory "$app/Contents/Resources"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done
binary="$app/Contents/MacOS/Outbound"
# The build points the binary at its own folders by absolute path; a shipped app looks only inside itself.
otool -l "$binary" | awk '/LC_RPATH/ { getline; getline; print $2 }' | while read -r path; do
    if [[ "$path" == /* ]]; then install_name_tool -delete_rpath "$path" "$binary"; fi
done

if [[ "$edition" == appstore ]]; then
    plist="$app/Contents/Info.plist"
    # The App Store does the updating, and there are no activation links to answer.
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval \
        SUVerifyUpdateBeforeExtraction CFBundleURLTypes; do
        plutil -remove "$key" "$plist"
    done
    [[ -n "${APPSTORE_BUILD:-}" ]] && plutil -replace CFBundleVersion -string "$APPSTORE_BUILD" "$plist"
    # Xcode stamps the tools an app was built with, and App Store Connect checks them.
    xcode_version="$(xcodebuild -version | awk '/^Xcode/ { print $2 }')"
    IFS=. read -r major minor patch <<< "$xcode_version"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
    plutil -insert DTXcode -string "$(printf '%d%d%d' "$major" "${minor:-0}" "${patch:-0}")" "$plist"
    plutil -insert DTXcodeBuild -string "$(xcodebuild -version | awk '/^Build version/ { print $3 }')" "$plist"
    plutil -insert DTSDKName -string "macosx$sdk_version" "$plist"
    plutil -insert DTSDKBuild -string "$sdk_build" "$plist"
    plutil -insert DTPlatformName -string macosx "$plist"
    plutil -insert DTPlatformVersion -string "$sdk_version" "$plist"
    plutil -insert DTPlatformBuild -string "$sdk_build" "$plist"
    plutil -insert DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$plist"
    plutil -insert BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$plist"
    plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$plist"
    cp Configuration/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
    # Kept beside the app for reading crash reports from the App Store.
    dsymutil "$bin/Outbound" -o "build/appstore/Outbound.dSYM" 2>/dev/null || true

    entitlements="$(mktemp)"
    cp Configuration/AppStore.entitlements "$entitlements"
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        cp "${APPSTORE_PROFILE:?Set APPSTORE_PROFILE to the Mac App Store provisioning profile}" \
            "$app/Contents/embedded.provisionprofile"
        codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$SIGN_IDENTITY" "$app"
    else
        # Only the sandbox: the store's identifiers need the provisioning profile.
        plutil -replace CFBundleIdentifier -string app.outbound.Outbound.adhoc "$plist"
        plutil -remove com\\.apple\\.application-identifier "$entitlements"
        plutil -remove com\\.apple\\.developer\\.team-identifier "$entitlements"
        codesign --force --entitlements "$entitlements" --sign - "$app"
    fi
    rm "$entitlements"
    if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
        pkg="build/appstore/Outbound.pkg"
        rm -f "$pkg"
        productbuild --component "$app" /Applications --sign "$INSTALLER_IDENTITY" "$pkg"
        echo "$pkg"
    fi
    echo "$app"
    exit 0
fi

# Sparkle, for updates, lives in Contents/Frameworks. Its XPC services are only for sandboxed apps.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
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
