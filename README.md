# Outbound

A painted world, flying by behind your Mac's desktop.

Fields, rivers and clouds drift past under your icons while a small white bird follows your cursor. Every place is real, shown in the season it is in today, under the light outside your window.

![Flooded rice paddies and sakura in Niigata, painted by Outbound](Website/assets/places/niigata.jpg)

[Website](https://outbound.edbn.me) · [Buy a license](https://outbound.edbn.me/#buy) · [Download](https://github.com/kewonit/outbound/releases/latest/download/Outbound.dmg)

## What it does

- **Real places.** Niigata, Punjab, the Serengeti, Normandy, Lisse, La Pampa, Lapland and Kansas, one after another, each turning into the next like paint spreading across paper. Fly to any of them from the menu bar.
- **Real seasons.** Each place shows what is growing there today: mustard in Punjab in February, the rice harvest in Niigata in October, snow on the fells in Lapland in winter. Or keep every place at its best.
- **Real light.** The sun follows your clock, so evenings bring long golden shadows and nights turn a moonlit blue.
- **Life passing by.** Now and then a train crosses in the place's own livery, a boat leaves its wake, or a skein of geese, a pair of cranes or a line of flamingos flies over.
- **Lights at night.** Windows light up house by house through the evening, street lamps come on along the village roads, a few at a time, and cars and trains light the way.
- **Each place itself.** Granite kopjes on the Serengeti, windmill pumps and estancia groves on the pampas, polder mills and glasshouses in Lisse, farmsteads and grain bins in Kansas, bogs and reindeer corrals in Lapland.
- **A bird that follows you.** Move the cursor over the desktop and the bird comes to circle it. One bird for all your displays, and it flies from one to the next.
- **Easy on the battery.** It stops drawing whenever the desktop is covered, the screen sleeps or locks, you are away, or Low Power Mode is on. On battery it flies at a lower frame rate and resolution, or holds a still painting if you prefer.
- **The lock screen matches.** While Outbound runs, your desktop picture is a painting of where you are. Quit it and your own picture comes back.

It needs a Mac with Apple silicon and macOS 26 or newer.

## Buying

Outbound costs $7 plus tax, once, for up to three of your Macs, sold through Polar.

- **From the app:** open Outbound and click Buy. Pay in your browser, and Outbound unlocks by itself a moment later, with nothing to copy.
- **From the [website](https://outbound.edbn.me/#buy):** after paying, the thank-you page has an Activate in Outbound button that unlocks the app, and shows your key too.

Your key is always in your [customer portal](https://polar.sh/edbnme/portal), where you can also free up a Mac you no longer use.

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

# Try the paid flow from a development build, against the live store or a local copy of the site.
OUTBOUND_GATED=1 .build/debug/Outbound
OUTBOUND_GATED=1 OUTBOUND_SHOP=http://localhost:8787/api .build/debug/Outbound   # with npx wrangler dev
```

Development builds answer `outbound-dev://` links, so they never take links meant for an installed copy.

`scripts/make-site-assets.sh` repaints every picture and video on the website.

## How it works

Each display gets a borderless window that sits just below the desktop icons, on every Space, and lets every click through to Finder.

The landscape is a set of Metal shaders that paint fields, rivers, roads, railways, trees, houses and snow from noise, with no images or video. The ground is painted once into a texture that wraps around in both directions, and as the camera flies north only the newly revealed strip is painted. Clouds never change shape, only drift, so they are painted at a quarter of the resolution and slid along. Each frame is then one render pass that stays in tile memory: the cached ground with cars, boats and trains, the herds as small instanced sprites, then the sky with clouds, birds, paper grain and the light of the hour. While the bird chases the cursor it moves to a small layer of its own, so following smoothly never means redrawing the whole landscape faster.

`Sources/OutboundCore` holds the parts that are plain logic, with tests: places and seasons, the journey, the bird's flight, the sun, the power policy and the license rules.

The website in `Website/` is served by a Cloudflare Worker, and `worker/index.js` adds a small API to it. When you buy from the app, the app asks the site to start a Polar checkout, opens it in your browser, and asks every few seconds whether it has been paid. Once it has, the Worker finds the license key Polar made for that order and hands it over, and the app activates it with Polar directly. The thank-you page after a website purchase does the same through an `outbound://activate` link that carries only the checkout, never the key.

## License

The code is public to read, learn from and improve, but Outbound is not free software. Using it needs a license, whether you download it or build it yourself, and you may not redistribute it. See [LICENSE](LICENSE).
