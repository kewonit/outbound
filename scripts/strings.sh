#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keeps Configuration/Localizable.xcstrings, the app's words in every language, in step with the code.
# The compiler lists every string the interface can show, SwiftUI's included, and the catalog takes in any new
# ones; then scripts/check-strings.py says which still need translating. The app build runs that check too.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
swift build --product Outbound --scratch-path "$scratch/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$scratch/strings"
xcrun xcstringstool sync Configuration/Localizable.xcstrings --stringsdata "$scratch"/strings/*.stringsdata
python3 scripts/check-strings.py
