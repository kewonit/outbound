import AppKit
import OutboundCore
import simd

/// The one landscape every display looks at, and the clock it runs on. World x runs east and world y
/// north, in metres; a global desktop point maps to the world by scaling and adding the camera.
@MainActor
final class World {
    /// Metres of ground per point on screen.
    static let metresPerPoint = 0.45
    /// Must match riverWaves in Common.metal.
    static let riverWaves = SIMD4<Double>(1530, 640, 3900, 271)
    static let roadWave = 2100.0
    static let crossroadSpacing = 1450.0
    /// How far the road keeps from the river.
    static let roadOffset = 150.0
    /// Height of the cloud layer, which sets how far cloud shadows fall from their clouds.
    static let cloudHeight = 70.0
    /// How high the camera flies, as clouds 70 m up slide past 1.15 times as fast as the land.
    static let cameraHeight = cloudHeight / (1 - 1 / 1.15)
    /// A light breeze. Up at the clouds it is the 1.3 by 0.55 m/s they drifted on until 1.7, so at Slow they cross the
    /// land at about its own pace rather than racing it.
    static let wind = SIMD2<Double>(1.3, 0.55) / 2.6
    /// The wind up where the clouds are, which carries them faster than the gusts it sends over the crops and the water.
    static let cloudWind = wind * 2.6
    static let gustWind = wind * 1.3
    /// About 33 km/h: unhurried country driving, still over a minute across the screen at Slow, and slower than trains.
    static let carSpeed = 9.2

    enum Light: String, CaseIterable {
        /// The sun as it stands at the place at your clock's time of day.
        case yourTime
        /// The sun as it stands at the place right now.
        case placeTime
        case alwaysDay
    }

    let journey: Journey
    private(set) var time: TimeInterval
    private(set) var bird: Bird
    /// The bird's last few poses, so each display draws it at the moment that display shows.
    private var birdTrail: BirdTrail
    private(set) var sun = Sun.fair
    /// The bird follows the cursor for a while after it last moved.
    private(set) var chasing = false
    var light = Light.yourTime {
        didSet { if light != oldValue { updateSun(force: true) } }
    }
    /// Where the cursor is, or nil when rendering without a screen.
    var pointer: () -> CGPoint? = { NSEvent.mouseLocation }
    /// The wall clock, for the sun.
    var now: () -> Date = { .now }
    /// Whether a point is over the bare desktop rather than over some app's window.
    var isDesktop: @MainActor (CGPoint) -> Bool = { World.desktopIsUnder($0) }
    private var overDesktop = false
    private var desktopChecked = -TimeInterval.infinity
    /// The display the bird circles when nobody is pointing.
    var home = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var lastPointer: CGPoint?
    private var pointerMoved = -TimeInterval.infinity
    private var sunUpdated = -TimeInterval.infinity
    /// Union of every display in global points, so the land is decided far enough ahead.
    var desktop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// World x the river meanders around.
    var riverX = 400.0
    var cloudCover = 0.42
    /// Bumped when something changes that is baked into the ground, so every display repaints it.
    private(set) var revision = 0

    init(place: Place, time: TimeInterval, date: Date = .now, light: Light = .yourTime) {
        self.time = time
        self.light = light
        journey = Journey(start: place, time: time, date: date, speed: 6.5, legLength: 6.5 * 60 * 12)
        bird = Bird(at: Bird.wander(in: home, time: time))
        birdTrail = BirdTrail(bird.pose, at: time)
        updateSun(force: true)
    }

    /// Opens on `moment` at `displayTime`, as on the painting the last run left on the desktop, say through a restart,
    /// so the view comes up showing just what the desktop did and sets off from there, gathering speed as it does after
    /// a hold. Only the light is as it is now. Nil when the moment can't be carried on from.
    init?(resuming moment: Moment, at displayTime: TimeInterval, date: Date = .now, light: Light = .yourTime) {
        guard moment.time.isFinite, displayTime.isFinite,
              let journey = Journey(moment.journey, date: date) else { return nil }
        time = moment.time
        self.light = light
        self.journey = journey
        lastBand = moment.band
        bird = moment.bird
        birdTrail = BirdTrail(bird.pose, at: time)
        heldFor = displayTime - moment.time
        setOff = displayTime
        updateSun(force: true)
    }

    /// The moment a display showing at `displayTime` should draw: its own time, less the time spent held still.
    /// Every display renders its own moment, so one never draws another's, while `advance` keeps the shared parts
    /// (the journey, the pointer, the bird and the sun) at the latest moment any of them asked for.
    func renderTime(for displayTime: TimeInterval) -> TimeInterval {
        if heldSince != nil { return time }
        if let settling {
            // Slowing to a stop is setting off played backwards, so what setting off leaves behind is the distance flown.
            return settling.from + Easing.rampLag(elapsed: displayTime - settling.since, length: Self.settleLength)
        }
        #if DEV
        return displayTime - heldFor - setOffLag(at: displayTime) + warpAhead(at: displayTime)
        #else
        return displayTime - heldFor - setOffLag(at: displayTime)
        #endif
    }

    /// The bird as it was, or is, at `t`.
    func birdPose(at t: TimeInterval) -> Bird.Pose {
        birdTrail.pose(at: t)
    }

    /// Time spent held still (asleep, locked, resting), taken off the clock so the flight carries on from where
    /// it stopped instead of leaping ahead. Opened on an earlier run's moment, it starts as the gap between that moment
    /// and the clock, which is less than nothing after a restart, as the clock starts again from zero.
    private var heldFor: TimeInterval = 0
    private var heldSince: TimeInterval?
    /// When the flight last set off again after being held, in display time. It gathers speed over `setOffLength`
    /// rather than going from still to full pace in one frame.
    private var setOff: TimeInterval?
    static let setOffLength = 0.8
    /// The flight coming to rest: when it began slowing, in display time, and its own time then.
    private var settling: (since: TimeInterval, from: TimeInterval)?
    /// How long the flight takes to come to rest, flying half that far as it does.
    static let settleLength = 0.5
    #if DEV
    /// Dev builds: the world running `scale` times as fast as the clock since `since`, in display time, or from when the
    /// flight next sets off while it is held.
    private var warp: (since: TimeInterval, scale: Double)?
    /// Dev builds: how far the clouds had drifted when their speed last changed, so a change never jumps them.
    private var cloudAnchor: (time: TimeInterval, drift: SIMD2<Double>, scale: Double)?
    /// Dev builds: a flight of birds set off by hand, and when, in world time.
    var forcedFlock: (flock: Flock, start: TimeInterval)?
    /// Dev builds: the leg whose train runs whatever its roll.
    var forcedTrainLeg: Int?
    #endif

    /// Brings the flight to rest over `settleLength`, as gently as it sets off, for `hold` to keep it there. Only a hold
    /// ends this, so a call to let go of a hold that isn't there leaves it slowing.
    func settle(at now: TimeInterval = CACurrentMediaTime()) {
        guard heldSince == nil, settling == nil else { return }
        settling = (now, renderTime(for: now))
    }

    func hold(_ on: Bool, at now: TimeInterval = CACurrentMediaTime()) {
        if on, heldSince == nil {
            #if DEV
            // Running fast stops with the flight, and sets off again with it, without a jump either way.
            if settling == nil { heldFor -= warpAhead(at: now) }
            warp = warp.map { (.infinity, $0.scale) }
            #endif
            if settling != nil {
                // Whatever the clock says, the flight carries on from where it slowed to, or from a frame already drawn
                // a little ahead of it, never going back.
                heldFor = now - max(time, renderTime(for: now))
                settling = nil
            } else {
                // What setting off last time took off the clock stays taken off.
                heldFor += setOffLag(at: now)
            }
            setOff = nil
            heldSince = now
        } else if !on, let since = heldSince {
            heldFor += now - since
            heldSince = nil
            setOff = now
            #if DEV
            warp = warp.map { (now, $0.scale) }
            #endif
        }
    }

    /// Something holds the flight still: the Mac asleep or locked, Pause, Low Power Mode and the like.
    var isHeld: Bool { heldSince != nil }

    /// How far behind its usual schedule gathering speed after a hold has left the flight.
    private func setOffLag(at displayTime: TimeInterval) -> TimeInterval {
        setOff.map { Easing.rampLag(elapsed: displayTime - $0, length: Self.setOffLength) } ?? 0
    }

    /// A moment of the flight to come back to: the one the painting on the desktop shows, which the wallpapers go back
    /// to as the Mac locks, so the desktop comes back just as the lock screen left it, and which the next launch opens
    /// on while that painting is still there.
    struct Moment: Codable {
        let time: TimeInterval
        let bird: Bird
        let revision: Int
        let cameraY: Double
        let journey: Journey.Snapshot
        /// A band left in view after a Fly To, which the journey no longer knows of.
        let band: Double?
    }

    func moment() -> Moment {
        Moment(time: time, bird: bird, revision: revision, cameraY: journey.cameraY(at: time), journey: journey.snapshot,
               band: lastBand)
    }

    /// How far back, in metres, the flight can go to a moment. The legs behind are kept that much longer.
    static let reach = 4000.0

    /// A Fly To is sweeping in a new place.
    var isSweeping: Bool {
        journey.legs.contains { $0.sweepStart.map { time - $0 < Journey.sweepDuration } ?? false }
    }

    /// Whether the world, held, can go back to `moment` and show just what it showed then: nothing baked into the
    /// ground has changed since, nor the pace, no Fly To has swept in a place since or was sweeping then, and the
    /// legs it showed are still kept.
    func canRewind(to moment: Moment) -> Bool {
        let bottom = moment.cameraY + Double(desktop.minY) * Self.metresPerPoint
        return heldSince != nil && moment.time <= time && moment.revision == revision
            && abs(journey.cameraY(at: moment.time) - moment.cameraY) < 0.01
            && !journey.legs.contains { ($0.sweepStart ?? -.infinity) > moment.time - Journey.sweepDuration }
            && camera.y - moment.cameraY < Self.reach && journey.leg(at: bottom).start <= bottom
    }

    /// Goes back to `moment` while held, so the flight carries on from there once released. The ground and the sky
    /// follow from the time alone; the bird goes back to where it was, and everything timed moves back with it.
    func rewind(to moment: Moment) {
        guard canRewind(to: moment) else { return }
        let back = time - moment.time
        time = moment.time
        heldFor += back
        pointerMoved -= back
        desktopChecked -= back
        sunUpdated -= back
        lastBand = moment.band
        bird = moment.bird
        birdTrail.reset(to: bird.pose, at: time)
    }

    func advance(to displayTime: TimeInterval) {
        guard heldSince == nil else { return }
        let t = renderTime(for: displayTime)
        guard t > time else { return }
        let dt = t - time
        time = t
        let camera = self.camera
        let top = camera.y + Double(desktop.maxY) * Self.metresPerPoint
        // The band over the whole desktop, whichever displays are drawing.
        let bottom = camera.y + Double(desktop.minY) * Self.metresPerPoint
        if let join = journey.joins.first(where: { Self.bandShows(over: $0, from: bottom, to: top) }) { lastBand = join }
        journey.extend(through: top + 1500,
                       behind: bottom - 1500 - Self.reach,
                       // Clear of the view, and of any band left in it, as only one shows at a time.
                       notBefore: max(top, (lastBand ?? -.infinity) + Double(desktop.height) * Self.metresPerPoint
                                      + Self.bankReach) + Self.bankReach + 20,
                       // Seasons by the world's own clock, which a render or a test may set.
                       date: now())

        // The bird only chases a cursor moving over the visible desktop, not one busy in another app.
        if let point = pointer() {
            if let last = lastPointer, abs(point.x - last.x) + abs(point.y - last.y) > 0.5 {
                if t - desktopChecked > 0.25 {
                    overDesktop = isDesktop(point)
                    desktopChecked = t
                }
                if overDesktop { pointerMoved = t }
            }
            lastPointer = point
        }
        chasing = t - pointerMoved < 10
        let target = chasing ? lastPointer.map { SIMD2(Double($0.x), Double($0.y)) } : nil
        bird.step(dt: dt, towards: target ?? Bird.wander(in: home, time: t), hurrying: target != nil)
        birdTrail.record(bird.pose, at: t)
        if t - sunUpdated > 20 { updateSun(force: false) }
    }

    /// The hour of the day where the scene is, and when the sun sets there, for switching lights on.
    private(set) var clock = (hour: 12.0, sunset: 19.0)

    /// How far a leg's herds have wandered; the same formula the animal sprites are laid out with.
    static func herdDrift(time: TimeInterval, seed: UInt32) -> SIMD2<Double> {
        let t = time.truncatingRemainder(dividingBy: 7200)
        return SIMD2(18 * sin(t * 2 * .pi * 3 / 7200 + Double(seed % 7)), 14 * sin(t * 2 * .pi * 2 / 7200 + 1.7))
    }

    private func updateSun(force: Bool) {
        sunUpdated = time
        let leg = journey.leg(at: camera.y)
        let place = leg.place
        let now = self.now()
        let calendar = Calendar.current
        // A place shown at its best is lit as it is in that season, so summer in the north isn't lit like December.
        let day = journey.followsCalendar ? calendar.ordinality(of: .day, in: .year, for: now) ?? 172 : leg.season.middleDay
        let next: Sun
        var hour = 12.0
        switch light {
        case .alwaysDay:
            next = .fair
        case .yourTime:
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
            next = Sun(latitude: place.anchor.latitude, dayOfYear: day, solarHour: hour)
        case .placeTime:
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let parts = utc.dateComponents([.hour, .minute], from: now)
            hour = (Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + place.anchor.longitude / 15 + 24)
                .truncatingRemainder(dividingBy: 24)
            next = Sun(latitude: place.anchor.latitude, dayOfYear: day, solarHour: hour)
        }
        clock = (hour, Sun.sunsetHour(latitude: place.anchor.latitude, dayOfYear: day))
        // Shadows are baked into the cached ground, so only repaint it when the light has really moved.
        let moved = abs(next.azimuth - sun.azimuth) + abs(next.elevation - sun.elevation)
        sun = next
        if force || moved > 0.06 { repaint() }
    }

    /// The seasons have changed: a place at its best is lit for the season it shows, so the sun moves with them, and
    /// the ground is painted again once, under the new sun.
    func seasonsChanged() {
        updateSun(force: true)
    }

    func repaint() {
        revision += 1
        legCache.removeAll()
        railCache.removeAll()
    }

    /// Each leg's shader parameters, built once rather than every frame.
    private var legCache: [Int: BiomeGPU] = [:]

    /// Holds the bird still for a picture.
    func poseBird(at point: CGPoint, heading: Double) {
        bird.pose(at: SIMD2(Double(point.x), Double(point.y)), heading: heading)
        birdTrail.reset(to: bird.pose, at: time)
    }

    /// The window a click at the point would reach. Wallpaper windows ignore the mouse, so over the desktop
    /// that is Finder's desktop, which sits below every normal window level.
    static func desktopIsUnder(_ point: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return true }
        // The wall clock, which keeps going while the Mac sleeps.
        let now = Date.now
        let layer: Int?
        if let last = lastWindow, last.number == number, abs(now.timeIntervalSince(last.read)) < 2 {
            layer = last.layer
        } else {
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
            layer = info?.first?[kCGWindowLayer as String] as? Int
            lastWindow = (number, layer, now)
        }
        guard let layer else { return true }
        return layer < 0
    }

    /// The level of the window last found under the pointer, read again every couple of seconds, so following the
    /// pointer across one window asks the window server once each time rather than twice.
    private static var lastWindow: (number: Int, layer: Int?, read: Date)?

    var camera: SIMD2<Double> {
        camera(at: time)
    }

    func camera(at t: TimeInterval) -> SIMD2<Double> {
        SIMD2(journey.cameraX(at: t), journey.cameraY(at: t))
    }

    /// The ground under a global desktop point.
    func ground(at point: CGPoint) -> SIMD2<Double> {
        ground(at: point, time: time)
    }

    func ground(at point: CGPoint, time t: TimeInterval) -> SIMD2<Double> {
        SIMD2(Double(point.x), Double(point.y)) * Self.metresPerPoint + camera(at: t)
    }

    /// Places the river a little right of centre on the given display, like the reference.
    func centreRiver(on frame: CGRect) {
        riverX = (Double(frame.midX) + Double(frame.width) * 0.12) * Self.metresPerPoint
    }

    struct Frame {
        var scene: SceneGPU
        /// World y the scene's positions are measured from, kept small enough for float precision.
        var reference: Double
        /// A Fly To repaint is under way: the world y of its leading edge, where the land is changing.
        var sweepFront: Double?
        var legA: Leg
        var legB: Leg
    }

    /// Everything the shaders share for a view that shows world y from `bottom` to `top`.
    func frame(bottom: Double, top: Double) -> Frame {
        frame(bottom: bottom, top: top, at: time)
    }

    func frame(bottom: Double, top: Double, at t: TimeInterval) -> Frame {
        let reference = (camera(at: t).y / 2048).rounded(.down) * 2048
        let topLeg = journey.leg(at: top)
        var legA = topLeg
        if let previous = journey.leg(before: topLeg), topLeg.start > bottom - 200 {
            legA = previous
        }
        let legB = topLeg

        var boundary = -1e9
        var sweep = -1.0
        var sweepFront: Double?
        if legA.index != legB.index {
            boundary = legB.start - reference
            if let start = legB.sweepStart {
                let progress = (t - start) / Journey.sweepDuration
                if progress < 1 {
                    sweep = max(progress, 0)
                    sweepFront = legB.start + sweep * (top - legB.start + 400)
                }
            }
        }

        func phase(_ wave: Double, _ offset: Double) -> Float {
            Float((reference / wave).truncatingRemainder(dividingBy: 2 * .pi) + offset)
        }
        let river = SIMD4<Float>(phase(Self.riverWaves.x, 0.3), phase(Self.riverWaves.y, 1.9),
                                 phase(Self.riverWaves.z, 4.1), phase(Self.riverWaves.w, 2.7))
        let bends = SIMD4<Float>(phase(Self.bendWaves.x, 5.2), phase(Self.bendWaves.y, 0.7),
                                 phase(Self.bendWaves.z, 3.3), Float((reference / Self.crossroadSpacing).rounded(.down)))
        // Traffic slots, counted from the world's origin so they survive the reference stepping on (see slotAt).
        let cars = Self.slots(speed: Self.carSpeed, spacing: Self.carSlot, time: t, reference: reference)
        // The river flows south, so boats heading north go against the current.
        let boats = Self.slots(speed: Self.boatSpeed - Self.current, spacing: Self.boatSlot, time: t, reference: reference)
        let downstream = Self.slots(speed: Self.boatSpeed + Self.current, spacing: Self.boatSlot, time: t,
                                    reference: reference)
        let crossPhase = Float(reference.positiveRemainder(Self.crossroadSpacing))
        let toSun = SIMD2<Float>(Float(sun.direction.x), Float(sun.direction.y))
        let light = sun.light

        let scene = SceneGPU(
            river: river,
            road: SIMD4(Float(riverX), Float(Self.roadOffset), phase(Self.roadWave, 0.8), crossPhase),
            sun: SIMD4(toSun.x, toSun.y, Float(sun.shadowLength), Float(sun.elevation)),
            light: SIMD4(Float(light.x), Float(light.y), Float(light.z), Float(light.w)),
            morph: SIMD4(Float(boundary), 0, Float(sweep), Float(top - legB.start)),
            time: SIMD4(Float(t.truncatingRemainder(dividingBy: 3600)),
                        Float(t.truncatingRemainder(dividingBy: 7200)), cars.phase, Float(sun.night)),
            clock: SIMD4(Float(clock.hour), Float(clock.sunset), boats.phase,
                         Float((reference + t * Self.current).positiveRemainder(256 * 64))),
            traffic: SIMD4(cars.north, cars.south, boats.north, downstream.south),
            bends: bends,
            train: train(reference: reference, at: t, legA: legA, legB: legB),
            legA: gpu(legA, reference: reference),
            legB: gpu(legB, reference: reference),
            water: SIMD4(downstream.phase,
                         Float((reference / Self.boatSlot).rounded(.down).positiveRemainder(Double(1 << 20))), 0, 0))
        return Frame(scene: scene, reference: reference, sweepFront: sweepFront, legA: legA, legB: legB)
    }

    private func gpu(_ leg: Leg, reference: Double) -> LegGPU {
        // Seeds stay below 2^24 so they survive the trip through a float.
        let seed = Float((UInt32(truncatingIfNeeded: leg.index &* 2_654_435_761 &+ 977) >> 8) & 0xffff)
        if legCache.count > 8 { legCache.removeAll() }
        let biome = legCache[leg.index] ?? BiomeGPU(leg.season.biome)
        legCache[leg.index] = biome
        var rail = SIMD4<Float>.zero, shape = SIMD4<Float>.zero
        var keeping = biome
        // Where the river runs, which a place without one still lines its road and its section grid up on.
        keeping.l.y = Float(riverX)
        if let line = railLine(for: leg) {
            rail = SIMD4(Float(line.origin.x), Float(line.origin.y), Float(line.angle), 1)
            shape = SIMD4(Float(line.amplitude), Float(line.wavelength), Float(line.phase),
                          leg.place.railway?.electrified == true ? 1 : 0)
            keeping.railLine = SIMD4(rail.x, rail.y, Float(cos(line.angle)), Float(sin(line.angle)))
            keeping.railCurve = SIMD4(shape.x, 1 / shape.y, shape.z, 1)
        }
        return LegGPU(biome: keeping, info: SIMD4(Float(leg.start - reference), seed, Float(leg.index), 0),
                      rail: rail, railShape: shape)
    }

    /// Through the water. Over the ground boats going upstream make that less the current, those going down that more.
    static let boatSpeed = 1.9
    /// How fast a river's surface slides downstream, in metres a second. Its threads repeat every 256 lattice cells of
    /// 64 m, so this is kept as how far along those it has come, counted from the world's origin (see viewGround).
    static let current = 0.35
    /// Must match carSlot, boatSlot and bendWaves in Common.metal. Slots divide 2048 m, the reference's step.
    static let carSlot = 128.0
    static let boatSlot = 512.0
    static let bendWaves = SIMD3<Double>(95, 61, 151)

    /// The fraction of a slot that traffic heading north has moved on, and how many slots traffic each way has
    /// passed, measured from the reference. The counts wrap only after a million slots.
    static func slots(speed: Double, spacing: Double, time t: TimeInterval, reference: Double)
        -> (phase: Float, north: Float, south: Float) {
        let north = (t * speed - reference) / spacing
        let south = (-t * speed - reference) / spacing
        let wrap = Double(1 << 20)
        return (Float(north - north.rounded(.down)), Float(north.rounded(.down).positiveRemainder(wrap)),
                Float(south.rounded(.down).positiveRemainder(wrap)))
    }
    /// When the main display's middle passes over the current leg's railway, worked out once per leg.
    private var trainCrossing: (leg: Int, time: TimeInterval, along: Double)?

    private var railCache: [Int: RailLine?] = [:]

    func railLine(for leg: Leg) -> RailLine? {
        if let cached = railCache[leg.index] { return cached }
        if railCache.count > 16 { railCache.removeAll() }
        let line = RailLine.line(for: leg, riverX: riverX, legLength: journey.legLength)
        railCache[leg.index] = line
        return line
    }

    /// The train passing the middle of the main display at `t`, if one is, for a view that shows `legA` below a join and
    /// `legB` above it, or one leg when they are the same. It is only ever drawn over its own place's land.
    private func train(reference: Double, at t: TimeInterval, legA: Leg? = nil, legB: Leg? = nil) -> TrainGPU {
        let centre = ground(at: CGPoint(x: home.midX, y: home.midY), time: t)
        var leg = journey.leg(at: centre.y)
        // A train still running carries on along its own line once the middle is over the next place, rather than
        // vanishing from track still in view.
        if let crossing = trainCrossing, crossing.leg != leg.index,
           let previous = journey.legs.first(where: { $0.index == crossing.leg }),
           let line = railLine(for: previous), let railway = previous.place.railway,
           line.train(at: t, crossing: crossing.time, middle: crossing.along, railway: railway,
                      seed: previous.index, always: runsTrain(on: previous)) != nil {
            leg = previous
        }
        guard let line = railLine(for: leg), let railway = leg.place.railway else { return .none }
        if trainCrossing?.leg != leg.index {
            trainCrossing = line.crossing(near: t, path: middlePath(over: leg)).map { (leg.index, $0.time, $0.along) }
        }
        guard let crossing = trainCrossing,
              let run = line.train(at: t, crossing: crossing.time, middle: crossing.along, railway: railway,
                                   seed: leg.index, always: runsTrain(on: leg)) else { return .none }
        func color(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(c, 1) }
        return TrainGPU(
            rail: SIMD4(Float(line.origin.x), Float(line.origin.y + leg.start - reference), Float(line.angle), 1),
            shape: SIMD4(Float(line.amplitude), Float(line.wavelength), Float(line.phase), 0),
            run: SIMD4(Float(run.head), Float(run.direction), Float(railway.carLength), Float(railway.cars)),
            info: SIMD4(Float(railway.locomotives), Float(railway.kind.rawValue), Float(Self.trainSide(of: leg, legA, legB)), 0),
            body: color(railway.body), stripe: color(railway.stripe), roof: color(railway.roof),
            locomotive: color(railway.locomotive))
    }

    /// Where the middle of the main display is over `leg`'s land at any time, following the camera's real path.
    private func middlePath(over leg: Leg) -> (TimeInterval) -> SIMD2<Double> {
        let offset = SIMD2(Double(home.midX), Double(home.midY)) * Self.metresPerPoint
        return { [journey] t in SIMD2(journey.cameraX(at: t), journey.cameraY(at: t) - leg.start) + offset }
    }

    /// Whether `leg`'s train runs whatever its roll, as a dev build can ask.
    private func runsTrain(on leg: Leg) -> Bool {
        #if DEV
        forcedTrainLeg == leg.index
        #else
        false
        #endif
    }

    /// Half the length of the bank of cloud over each join between two places, in metres: a thin band across the land.
    static let bankHalf = 75.0
    /// How far from a join anything of its bank can be seen: its ragged edge comes up to 147 m out (bankReach in
    /// Clouds.metal), and its shadow can fall a cloud's height times the longest shadow beyond that.
    static let bankReach = 150 + cloudHeight * Sun.longestShadow

    /// The last join whose band was in view. A Fly To takes the place beyond a join away, but cloud already in view stays
    /// in the sky and drifts off with the land.
    private var lastBand: Double?

    /// World y of the join whose band shows anywhere from `bottom` to `top`, if one does.
    func bank(from bottom: Double, to top: Double) -> Double? {
        let shows = { (join: Double) in Self.bandShows(over: join, from: bottom, to: top) }
        return journey.joins.first(where: shows) ?? lastBand.flatMap { shows($0) ? $0 : nil }
    }

    private static func bandShows(over join: Double, from bottom: Double, to top: Double) -> Bool {
        join - bankReach < top && join + bankReach > bottom
    }

    /// Whether the middle of the main display has reached the first join between two places.
    var handoverPassing: Bool {
        journey.leg(at: camera.y + Double(home.midY) * Self.metresPerPoint).index > 0
    }

    /// Where over a view showing `legA` below a join and `legB` above it the train on `leg`'s line may be drawn: 0
    /// everywhere, 1 below the join, 2 above it, 3 nowhere, as that view shows other places.
    static func trainSide(of leg: Leg, _ legA: Leg?, _ legB: Leg?) -> Int {
        guard let legA, let legB else { return 0 }
        if legA.index == legB.index { return leg.index == legA.index ? 0 : 3 }
        return leg.index == legA.index ? 1 : leg.index == legB.index ? 2 : 3
    }

    /// Whether a train is passing the middle of the main display.
    var trainPassing: Bool {
        train(reference: 0, at: time).rail.w > 0
    }

    /// The flock in the sky over the desktop right now, if any, and what kind of birds they are.
    var flock: (Flock, FlockSighting)? {
        flock(at: time)
    }

    func flock(at t: TimeInterval) -> (Flock, FlockSighting)? {
        let centre = ground(at: CGPoint(x: home.midX, y: home.midY), time: t)
        let leg = journey.leg(at: centre.y)
        #if DEV
        if let forced = forcedFlock, let sighting = sighting(of: forced.flock, at: t, startedAt: forced.start) {
            return (forced.flock, sighting)
        }
        #endif
        guard let flock = Flock.of(leg.place, month: month(at: now())) else { return nil }
        guard let sighting = flock.sighting(at: t, area: desktop,
                                             seed: leg.place.id.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) } & 0xffff,
                                             drift: landDrift(for: flock, at: t), wind: Self.wind / Self.metresPerPoint)
        else { return nil }
        return (flock, sighting)
    }

    /// How far the land has carried `flock` since a moment `since` before `t`, in points. Lower than the camera, birds
    /// slide past faster than the land does, the higher the more; circling birds ride a thermal the wind carries.
    private func landDrift(for flock: Flock, at t: TimeInterval) -> (TimeInterval) -> SIMD2<Double> {
        let k = 1 / (1 - flock.altitude / Self.cameraHeight)
        return { [self] since in (camera(at: t - since) - camera(at: t)) * k / Self.metresPerPoint }
    }

    /// The month by the clock, when it begins and ends, and when that was worked out, so asking every frame costs a
    /// comparison rather than a calendar sum. It is worked out again every minute, as a new time zone or calendar moves
    /// where months begin.
    private var clockMonth: (number: Int, start: Date, end: Date, asked: Date)?

    private func month(at date: Date) -> Int {
        if let month = clockMonth, date >= month.start, date < month.end, abs(date.timeIntervalSince(month.asked)) < 60 {
            return month.number
        }
        let calendar = Calendar.current
        let number = calendar.component(.month, from: date)
        clockMonth = calendar.dateInterval(of: .month, for: date).map { (number, $0.start, $0.end, date) }
        return number
    }

    /// Cloud space for a point `metres` from the desktop origin: clouds drift with the wind and, being
    /// nearer the camera, slide past a little faster than the ground.
    func cloudSpace(_ metres: SIMD2<Double>, at t: TimeInterval) -> SIMD2<Double> {
        #if DEV
        let p = metres + camera(at: t) * 1.15 - cloudDrift(at: t)
        #else
        let p = metres + camera(at: t) * 1.15 - Self.cloudWind * t
        #endif
        return SIMD2(p.x.positiveRemainder(16384), p.y.positiveRemainder(16384))
    }

    /// Space for the gusts rolling over the crops, which travel with the wind across the ground.
    func gustSpace(_ metres: SIMD2<Double>, at t: TimeInterval) -> SIMD2<Double> {
        let p = metres + camera(at: t) - Self.gustWind * t
        return SIMD2(p.x.positiveRemainder(55 * 1024), p.y.positiveRemainder(160 * 1024))
    }
}

extension Double {
    func positiveRemainder(_ divisor: Double) -> Double {
        let r = truncatingRemainder(dividingBy: divisor)
        return r < 0 ? r + divisor : r
    }
}

extension Int {
    func positiveRemainder(_ divisor: Int) -> Int {
        let r = self % divisor
        return r < 0 ? r + divisor : r
    }
}

#if DEV
/// Dev builds: ways to bring on what would otherwise take a long wait.
extension World {
    /// How far running fast has taken the flight ahead of its usual schedule at `displayTime`.
    private func warpAhead(at displayTime: TimeInterval) -> TimeInterval {
        guard let warp else { return 0 }
        return (warp.scale - 1) * max(0, displayTime - warp.since)
    }

    /// How many times as fast as the clock the world runs.
    var timeScale: Double { warp?.scale ?? 1 }

    /// Runs the world `scale` times as fast as the clock from now on, carrying on from just where it is.
    func setTimeScale(_ scale: Double, at now: TimeInterval = CACurrentMediaTime()) {
        heldFor -= warpAhead(at: now)
        warp = scale == 1 ? nil : (isHeld ? .infinity : now, scale)
    }

    /// Jumps the flight `seconds` ahead, as if that long had gone by. It shows once the flight next moves.
    func skip(_ seconds: TimeInterval) {
        heldFor -= seconds
    }

    private func cloudDrift(at t: TimeInterval) -> SIMD2<Double> {
        guard let anchor = cloudAnchor else { return Self.cloudWind * t }
        return anchor.drift + Self.cloudWind * anchor.scale * (t - anchor.time)
    }

    /// How many times as fast as the wind the clouds drift.
    var cloudSpeed: Double { cloudAnchor?.scale ?? 1 }

    /// Lets the clouds drift `scale` times as fast as the wind from now on, from just where they are.
    func setCloudSpeed(_ scale: Double) {
        cloudAnchor = (time, cloudDrift(at: time), scale)
    }

    /// The flock this place has this month, if any.
    var flockHere: Flock? {
        let centre = ground(at: CGPoint(x: home.midX, y: home.midY), time: time)
        return Flock.of(journey.leg(at: centre.y).place, month: month(at: now()))
    }

    /// Sends `flock` over the desktop now, whatever the place and month.
    func bringFlock(_ flock: Flock) {
        forcedFlock = (flock, time)
    }

    fileprivate func sighting(of flock: Flock, at t: TimeInterval, startedAt start: TimeInterval) -> FlockSighting? {
        flock.flight(startedAt: start, at: t, area: desktop, seed: 7, drift: landDrift(for: flock, at: t),
                     wind: Self.wind / Self.metresPerPoint)
    }

    /// Seconds until the middle of the main display passes over this place's railway, with its train running then
    /// whatever its roll, or nil if the place has no railway here or the flight has already passed it.
    func trainAhead() -> TimeInterval? {
        let centre = ground(at: CGPoint(x: home.midX, y: home.midY), time: time)
        let leg = journey.leg(at: centre.y)
        guard let line = railLine(for: leg),
              let crossing = line.crossing(near: time, path: middlePath(over: leg)), crossing.time > time - 30
        else { return nil }
        forcedTrainLeg = leg.index
        trainCrossing = (leg.index, crossing.time, crossing.along)
        return crossing.time - time
    }

    /// Brings on the next place as soon as it can come into view. Only one band shows at a time, so it waits while
    /// one is in view, and returns false.
    func moveOn() -> Bool {
        let bottom = camera.y + Double(desktop.minY) * Self.metresPerPoint
        let top = camera.y + Double(desktop.maxY) * Self.metresPerPoint
        guard bank(from: bottom, to: top) == nil else { return false }
        journey.moveOn(after: top + Self.bankReach)
        return true
    }

    /// Back to the world as it runs: the clock's own pace, the wind's clouds and no flock or train brought on.
    func clearDevOverrides() {
        setTimeScale(1)
        if cloudAnchor != nil { setCloudSpeed(1) }
        forcedFlock = nil
        forcedTrainLeg = nil
    }
}
#endif
