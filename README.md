<img src="Website/assets/og.png" alt="Outbound: a painted world, flying by behind your desktop" width="100%">

**A live wallpaper for Mac.** A painted world drifts by behind your desktop, and a little bird follows your cursor.

**[Buy for $7](https://outbound.edbn.me/#buy)** · [Download](https://outbound.edbn.me/download) · [Website](https://outbound.edbn.me)

<p>
  <img src="Website/assets/demos/follow.jpg" alt="The bird following the cursor" width="49%">
  <img src="Website/assets/demos/night.jpg" alt="A village at night" width="49%">
  <img src="Website/assets/demos/train.jpg" alt="A train crossing the paddies" width="49%">
  <img src="Website/assets/demos/flock.jpg" alt="Geese over the tulip fields" width="49%">
</p>

### Eight real places

<p>
  <img src="Website/assets/places/niigata.jpg" alt="Niigata, Japan" width="24%">
  <img src="Website/assets/places/punjab.jpg" alt="Punjab, India" width="24%">
  <img src="Website/assets/places/lisse.jpg" alt="Lisse, Netherlands" width="24%">
  <img src="Website/assets/places/serengeti.jpg" alt="Serengeti, Tanzania" width="24%">
  <img src="Website/assets/places/normandy.jpg" alt="Normandy, France" width="24%">
  <img src="Website/assets/places/kansas.jpg" alt="Kansas, United States" width="24%">
  <img src="Website/assets/places/lapland.jpg" alt="Lapland, Finland" width="24%">
  <img src="Website/assets/places/pampa.jpg" alt="La Pampa, Argentina" width="24%">
</p>

### The light follows your clock

<p>
  <img src="Website/assets/day/morning.jpg" alt="Morning" width="24%">
  <img src="Website/assets/day/noon.jpg" alt="Noon" width="24%">
  <img src="Website/assets/day/evening.jpg" alt="Evening" width="24%">
  <img src="Website/assets/day/night.jpg" alt="Night" width="24%">
</p>

Needs a Mac with Apple silicon and macOS 13 Ventura or newer. $7 + tax, once, for up to 3 Macs.

## Build

```sh
scripts/build-app.sh debug
open build/Outbound.app
```

Ship an update to everyone: `scripts/release.sh 1.1 "What's new."`

The Mac App Store edition is the same code, sandboxed, without the updater or the license store: `scripts/build-app.sh appstore` builds it, and `scripts/appstore.sh` sends it to App Store Connect.

## License

The code is open to read and improve. Using the app needs a license. See [LICENSE](LICENSE).
