#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Paints the website's pictures and videos with the app's own renderer. Needs ffmpeg.
# Everything is drawn by the same shaders as the wallpaper; --caption adds the place name as it sits in the
# corner of the desktop, and --cursor moves a pointer for the bird to follow.
swift build --product Outbound
outbound="$(swift build --show-bin-path)/Outbound"
assets=Website/assets
mkdir -p "$assets/places" "$assets/demos" "$assets/day"

# video <file> <width> <height> <seconds> <renderer options...>, in points at Retina scale, as on a MacBook.
video() {
    local file=$1 width=$2 height=$3 seconds=$4
    shift 4
    "$outbound" --render - --size "${width}x${height}" --scale 2 --seconds "$seconds" --fps 30 "$@" \
        | ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s "$((width * 2))x$((height * 2))" -r 30 -i - \
            -c:v libx264 -pix_fmt yuv420p -crf 25 -preset slow -movflags +faststart "$file"
    ffmpeg -y -loglevel error -i "$file" -frames:v 1 -q:v 3 "${file%.mp4}.jpg"
}

# The places, each in the season it is known for, at a moment with a landmark in view.
for entry in punjab:45 niigata:45 serengeti:150 normandy:45 lisse:45 pampa:45 lapland:45 kansas:260; do
    place=${entry%%:*}
    "$outbound" --render "$assets/places/$place.jpg" --place "$place" --best --time "${entry##*:}" \
        --size 1200x780 --scale 1
done
# The picture shown when a link to the site is shared.
"$outbound" --og "$assets/og.png"

# The hero: Punjab in flower, with the bird coming to the cursor. The page lays a Dock over the bottom, so the
# caption sits above it as on a Mac.
video "$assets/flight.mp4" 800 500 16 --place punjab --best --time 30 --caption --dock 58 --cursor
mv "$assets/flight.jpg" "$assets/poster.jpg"

# Short demos of what happens now and then.
video "$assets/demos/follow.mp4" 640 400 12 --place niigata --best --time 30 --caption --cursor
video "$assets/demos/night.mp4" 640 400 12 --place niigata --best --hour 21.5 --time 1490 --caption
video "$assets/demos/train.mp4" 640 400 12 --place niigata --best --time 30 --find train --after 34 --caption
video "$assets/demos/flock.mp4" 640 400 14 --place lisse --date 2026-04-12 --time 30 --find flock --after 10 --caption
video "$assets/demos/fly.mp4" 640 400 9 --place punjab --best --time 30 --fly-to lisse --fly-at 2.5 --caption

# A village in Normandy through one April day, from morning to night.
for moment in morning:8 noon:13 evening:18.2 night:21.3; do
    "$outbound" --render "$assets/day/${moment%%:*}.jpg" --place niigata --best --date 2026-04-20 \
        --hour "${moment##*:}" --time 1490 --size 600x400 --scale 2
done
