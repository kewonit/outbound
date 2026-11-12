<img src="Website/public/assets/og.jpg" alt="Outbound: a painted world, flying by behind your desktop" width="100%">

**A live wallpaper for Mac.** A painted world drifts by behind your desktop, and a little bird follows your cursor.

**[Buy for $4.99](https://outbound.edbn.me/#buy)** · [Download](https://outbound.edbn.me/download) · [Website](https://outbound.edbn.me)

<p>
  <img src="Website/public/assets/demos/follow.jpg" alt="The bird following the cursor" width="49%">
  <img src="Website/public/assets/demos/night.jpg" alt="A village at night" width="49%">
  <img src="Website/public/assets/demos/train.jpg" alt="A train crossing the paddies" width="49%">
  <img src="Website/public/assets/demos/flock.jpg" alt="Geese over the tulip fields" width="49%">
</p>

### Eight real places

<p>
  <img src="Website/public/assets/places/niigata.jpg" alt="Niigata, Japan" width="24%">
  <img src="Website/public/assets/places/punjab.jpg" alt="Punjab, India" width="24%">
  <img src="Website/public/assets/places/lisse.jpg" alt="Lisse, Netherlands" width="24%">
  <img src="Website/public/assets/places/serengeti.jpg" alt="Serengeti, Tanzania" width="24%">
  <img src="Website/public/assets/places/normandy.jpg" alt="Normandy, France" width="24%">
  <img src="Website/public/assets/places/kansas.jpg" alt="Kansas, United States" width="24%">
  <img src="Website/public/assets/places/lapland.jpg" alt="Lapland, Finland" width="24%">
  <img src="Website/public/assets/places/pampa.jpg" alt="La Pampa, Argentina" width="24%">
</p>

### The light follows your clock

<p>
  <img src="Website/public/assets/day/morning.jpg" alt="Morning" width="24%">
  <img src="Website/public/assets/day/noon.jpg" alt="Noon" width="24%">
  <img src="Website/public/assets/day/evening.jpg" alt="Evening" width="24%">
  <img src="Website/public/assets/day/night.jpg" alt="Night" width="24%">
</p>

Needs a Mac with Apple silicon and macOS 13 Ventura or newer. $4.99 + tax, once, for 1 Mac.

## Build

```sh
scripts/build-app.sh debug
open build/Outbound.app
```

Ship an update to everyone: `scripts/release.sh 1.1 "What's new."`

Before changing the shaders or the renderer, run `scripts/perf.sh keep`, and afterwards `scripts/perf.sh check`: it
compares GPU time a frame, memory, shader compile time and the pictures themselves with the build that was kept. After
any change to the shaders also run `scripts/perf.sh steady`, which paints one frame 1,200 times and fails unless every
painting is the same.

The website is in `Website/`, built with Astro to plain HTML. `npm install` once, then `npm run dev` to work on the
pages, or `npm run preview` to build them and run the Worker too. English words are in `Website/src/i18n/en.json`,
and the build stops until every other language has the same keys.

## License

The code is open to read and improve. Using the app needs a license. See [LICENSE](LICENSE).
