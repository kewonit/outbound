#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Paints the website's pictures and the hero video with the app's own renderer. Needs ffmpeg.
swift build --product Outbound
outbound="$(swift build --show-bin-path)/Outbound"
assets=Website/assets
mkdir -p "$assets/places"

for place in punjab niigata serengeti normandy lisse pampa lapland kansas; do
    "$outbound" --render "$assets/places/$place.jpg" --place "$place" --best --time 45 --size 1200x780 --scale 1
done
"$outbound" --render "$assets/og-image.png" --place niigata --best --time 40 --size 1200x630 --scale 1
"$outbound" --render "$assets/poster.jpg" --place punjab --best --time 30 --size 1600x1000 --scale 1
"$outbound" --render - --place punjab --best --time 30 --size 1600x1000 --scale 1 --seconds 16 --fps 30 \
    | ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s 1600x1000 -r 30 -i - \
        -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart "$assets/flight.mp4"
