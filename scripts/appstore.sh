#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Sends the version already in Configuration/Info.plist to App Store Connect, where it goes to TestFlight and
# then to review:
#
#     scripts/appstore.sh          # as built by scripts/release.sh
#     scripts/appstore.sh 6.1      # the same version again, after a rejection: a build number of its own
#
# Ship the version with scripts/release.sh first, so the download and the App Store carry the same code.
# Needs the Apple Distribution and Mac Installer Distribution identities in the login keychain, the Mac App
# Store provisioning profile (APPSTORE_PROFILE, by default in ~/Documents), and an App Store Connect API key:
# its .p8 in ~/.appstoreconnect/private_keys, its ids in ASC_KEY_ID and ASC_ISSUER_ID.
build="${1:-}"
team="Kartik Kulloli (55W3P96VL4)"
profile="${APPSTORE_PROFILE:-$HOME/Documents/Outbound App Store.provisionprofile}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect API key id}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect API issuer id}"
[[ -f "$profile" ]] || { echo "No provisioning profile at $profile" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Upload from main." >&2; exit 1; }

SIGN_IDENTITY="Apple Distribution: $team" INSTALLER_IDENTITY="3rd Party Mac Developer Installer: $team" \
    APPSTORE_PROFILE="$profile" APPSTORE_BUILD="$build" scripts/build-app.sh appstore
pkg=build/appstore/Outbound.pkg
key=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
xcrun altool --validate-app --type macos --file "$pkg" "${key[@]}"
xcrun altool --upload-app --type macos --file "$pkg" "${key[@]}"
echo "Uploaded $(plutil -extract CFBundleShortVersionString raw Configuration/Info.plist) to App Store Connect."
echo "It shows in TestFlight once Apple has processed it, usually within the hour."
