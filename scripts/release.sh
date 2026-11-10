#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Ships a new version to everyone:
#
#     scripts/release.sh 1.1 "What's new, in a sentence or two."
#
# It bumps the version, builds, signs and notarizes the app, publishes it as a GitHub release, and adds it to
# the appcast and the changelog on the website. Every copy checks that appcast once a day, downloads the update, checks its
# signature, and installs it the next time the Mac is left alone.
#
# Needs the Developer ID identity, the outbound-notary profile, and Sparkle's signing key in the login
# keychain (made once with generate_keys --account app.outbound.Outbound; keep a backup of it).
usage='Usage: scripts/release.sh <version> "<what is new>"'
version="${1:?$usage}"
notes="${2:?$usage}"
identity="Developer ID Application: Kartik Kulloli (55W3P96VL4)"
plist=Configuration/Info.plist
appcast=Website/appcast.xml

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main." >&2; exit 1; }
git pull --ff-only --quiet
! gh release view "v$version" >/dev/null 2>&1 || { echo "v$version is already out." >&2; exit 1; }
swift package resolve >/dev/null
sign_update=.build/artifacts/sparkle/Sparkle/bin/sign_update

# The new version, and a build number one past the last, which is what Sparkle compares.
build=$(( $(plutil -extract CFBundleVersion raw "$plist") + 1 ))
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$version</string>|;}" "$plist"
sed -i '' "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>$build</string>|;}" "$plist"
git commit --quiet -am "Outbound $version"
git push --quiet origin main

SIGN_IDENTITY="$identity" NOTARY_PROFILE=outbound-notary scripts/build-app.sh release
dmg="build/Outbound-v$version.dmg"
zip="build/Outbound-v$version.zip"
cp build/Outbound.dmg "$dmg"
cp build/Outbound.zip "$zip"

# Publish the disk image first, so the appcast never points at a file that isn't there yet.
gh release create "v$version" "$dmg" "$zip" --target "$(git rev-parse HEAD)" \
    --title "Outbound v$version" --notes "$notes"

# Then offer it to every copy: the newest item goes first in the appcast.
signature=$("$sign_update" --account app.outbound.Outbound "$dmg")
item="    <item>
      <title>Outbound v$version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <description><![CDATA[<p>$notes</p>]]></description>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(plutil -extract LSMinimumSystemVersion raw Configuration/Info.plist)</sparkle:minimumSystemVersion>
      <enclosure url=\"https://github.com/kewonit/outbound/releases/download/v$version/Outbound-v$version.dmg\" type=\"application/octet-stream\" $signature/>
    </item>"
ITEM="$item" awk '{ print } /<language>/ && !done { print ENVIRON["ITEM"]; done = 1 }' "$appcast" > "$appcast.new"
mv "$appcast.new" "$appcast"

# And at the top of the changelog, with the notes as its line, unless it already has one. Fill it out by hand later.
changelog=Website/changelog.html
if ! grep -q "id=\"v$version\"" "$changelog"; then
    said=$(printf '%s' "$notes" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    entry="    <article class=\"release\" id=\"v$version\">
      <header class=\"release-head\">
        <h2><a href=\"#v$version\">$version</a></h2>
        <time datetime=\"$(date +%F)\">$(LC_ALL=C date "+%-d %B %Y")</time>
      </header>
      <div class=\"release-body\">
        <p>$said</p>
      </div>
    </article>
"
    ENTRY="$entry" awk '{ print } /<!-- releases:/ && !done { print ENVIRON["ENTRY"]; done = 1 }' "$changelog" > "$changelog.new"
    mv "$changelog.new" "$changelog"
    sed -i '' "s|\(<loc>https://outbound.edbn.me/changelog</loc><lastmod>\)[^<]*|\1$(date +%F)|" Website/sitemap.xml
fi
git commit --quiet -am "Offer Outbound v$version as an update"
git push --quiet origin main
echo "Outbound v$version is out. Copies will pick it up within a day."
