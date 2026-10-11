#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-debug}"
swift build -c "$configuration" --product Outbound
bin="$(swift build -c "$configuration" --show-bin-path)"

app="build/Outbound.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Outbound" "$app/Contents/MacOS/"
cp Configuration/Info.plist "$app/Contents/"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"
echo "$app"
