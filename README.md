# Outbound

A painted world, flying by behind your Mac's desktop.

Fields, rivers and clouds drift past under your icons while a small white bird follows your cursor. Every place is real, shown in the season it is in today, under the light outside your window.

![Flooded rice paddies and sakura in Niigata, painted by Outbound](Website/assets/places/niigata.jpg)

[Website](https://outbound.edbn.me) · [Buy a license](https://outbound.edbn.me/#buy) · [Download](https://github.com/kewonit/outbound/releases/latest/download/Outbound.dmg)

## What it does

- **Real places.** Niigata, Punjab, the Serengeti, Normandy, Lisse, La Pampa, Lapland and Kansas, one after another, each turning into the next like paint spreading across paper. Fly to any of them from the menu bar.
- **Real seasons.** Each place shows what is growing there today: mustard in Punjab in February, the rice harvest in Niigata in October, snow on the fells in Lapland in winter. Or keep every place at its best.
- **Real light.** The sun follows your clock, so evenings bring long golden shadows and nights turn a moonlit blue.
- **A bird that follows you.** Move the cursor over the desktop and the bird comes to circle it. One bird for all your displays, and it flies from one to the next.
- **Easy on the battery.** It stops drawing whenever the desktop is covered, the screen sleeps or locks, and in Low Power Mode. On battery it flies at a lower frame rate, or holds a still painting if you prefer.
- **The lock screen matches.** Your desktop picture is kept as a painting of where you are, and your old one can be put back from Settings.

It needs macOS 26 or newer.

## Buying

Outbound costs $7, once, for up to three of your Macs. Buy a key on the [website](https://outbound.edbn.me/#buy), download the app, and paste the key from your receipt when it asks.

## Building it yourself

You need Xcode 26 or newer.

```sh
swift test
scripts/build-app.sh debug    # build/Outbound.app, signed ad hoc
open build/Outbound.app
```

Debug builds run without a license key and say "Development build" in the corner. Release builds ask for a key. Using Outbound day to day needs a license either way; see [LICENSE](LICENSE).

While working on the painting:

```sh
# Recompile the shaders whenever one is saved.
OUTBOUND_SHADERS=$PWD/Sources/Outbound/Shaders .build/debug/Outbound

# Paint one frame, or a video, without opening any windows.
.build/debug/Outbound --render punjab.png --place punjab --date 2026-02-10 --hour 17.5 --size 1512x982 --scale 2
.build/debug/Outbound --render - --place niigata --best --seconds 16 --size 1600x1000 --scale 1 \
    | ffmpeg -f rawvideo -pix_fmt bgra -s 1600x1000 -r 30 -i - flight.mp4

# Test licensing against Polar's sandbox.
OUTBOUND_POLAR_SANDBOX=1 OUTBOUND_POLAR_ORGANIZATION=<sandbox organization id> .build/debug/Outbound
```

`scripts/make-site-assets.sh` repaints every picture and the video on the website.

## How it works

Each display gets a borderless window that sits just below the desktop icons, on every Space, and lets every click through to Finder.

The landscape is a set of Metal shaders that paint fields, rivers, roads, trees, houses and snow from noise, with no images or video. The ground is painted once into a texture that wraps around in both directions, and as the camera flies north only the newly revealed strip is painted. Clouds never change shape, only drift, so they are painted at a quarter of the resolution and slid along. That leaves each frame mostly copying, plus the few things that move: the bird, the animals, the cars and the glints on the water.

`Sources/OutboundCore` holds the parts that are plain logic, with tests: places and seasons, the journey, the bird's flight, the sun, the power policy and the license rules.

## License

The code is public to read, learn from and improve, but Outbound is not free software. Using it needs a license, whether you download it or build it yourself, and you may not redistribute it. See [LICENSE](LICENSE).
