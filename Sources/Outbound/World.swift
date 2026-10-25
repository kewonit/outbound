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
    static let wind = SIMD2<Double>(2.6, 1.1)
    static let carSpeed = 11.0

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
    private(set) var sun = Sun.fair
    /// The bird follows the cursor for a while after it last moved.
    private(set) var chasing = false {
        didSet { if chasing != oldValue { onChasingChange(chasing) } }
    }
    var onChasingChange: (Bool) -> Void = { _ in }
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
        updateSun(force: true)
    }

    func advance(to t: TimeInterval) {
        guard t > time else { return }
        let dt = t - time
        time = t
        let camera = self.camera
        journey.extend(through: camera.y + Double(desktop.maxY) * Self.metresPerPoint + 1500,
                       behind: camera.y + Double(desktop.minY) * Self.metresPerPoint - 1500)

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
        chasing = t - pointerMoved < 6
        let target = chasing ? lastPointer.map { SIMD2(Double($0.x), Double($0.y)) } : nil
        bird.step(dt: dt, towards: target ?? Bird.wander(in: home, time: t))
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
        let place = journey.leg(at: camera.y).place
        let now = self.now()
        let calendar = Calendar.current
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 172
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

    func repaint() {
        revision += 1
    }

    /// Holds the bird still for a picture.
    func poseBird(at point: CGPoint, heading: Double) {
        bird.pose(at: SIMD2(Double(point.x), Double(point.y)), heading: heading)
    }

    /// The window a click at the point would reach. Wallpaper windows ignore the mouse, so over the desktop
    /// that is Finder's desktop, which sits below every normal window level.
    static func desktopIsUnder(_ point: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let layer = info.first?[kCGWindowLayer as String] as? Int else { return true }
        return layer < 0
    }

    var camera: SIMD2<Double> {
        SIMD2(journey.cameraX(at: time), journey.cameraY(at: time))
    }

    /// The ground under a global desktop point.
    func ground(at point: CGPoint) -> SIMD2<Double> {
        SIMD2(Double(point.x), Double(point.y)) * Self.metresPerPoint + camera
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
        let reference = (camera.y / 2048).rounded(.down) * 2048
        let topLeg = journey.leg(at: top)
        var legA = topLeg
        if let previous = journey.leg(before: topLeg), topLeg.start + Journey.morphLength > bottom - 200 {
            legA = previous
        }
        let legB = topLeg

        var boundary = -1e9
        var length = Journey.morphLength
        var sweep = -1.0
        var sweepFront: Double?
        if legA.index != legB.index {
            boundary = legB.start - reference
            if let start = legB.sweepStart {
                let progress = (time - start) / Journey.sweepDuration
                if progress < 1 {
                    sweep = max(progress, 0)
                    sweepFront = legB.start + sweep * (top - legB.start + 400)
                } else {
                    length = 0.001
                }
            }
        }

        func phase(_ wave: Double, _ offset: Double) -> Float {
            Float((reference / wave).truncatingRemainder(dividingBy: 2 * .pi) + offset)
        }
        let river = SIMD4<Float>(phase(Self.riverWaves.x, 0.3), phase(Self.riverWaves.y, 1.9),
                                 phase(Self.riverWaves.z, 4.1), phase(Self.riverWaves.w, 2.7))
        let crossPhase = Float(reference.truncatingRemainder(dividingBy: Self.crossroadSpacing))
        let toSun = SIMD2<Float>(Float(sun.direction.x), Float(sun.direction.y))
        let light = sun.light

        let scene = SceneGPU(
            river: river,
            road: SIMD4(Float(riverX), Float(Self.roadOffset), phase(Self.roadWave, 0.8), crossPhase),
            sun: SIMD4(toSun.x, toSun.y, Float(sun.shadowLength), Float(sun.elevation)),
            light: SIMD4(Float(light.x), Float(light.y), Float(light.z), Float(light.w)),
            morph: SIMD4(Float(boundary), Float(length), Float(sweep), Float(top - legB.start)),
            time: SIMD4(Float(time.truncatingRemainder(dividingBy: 3600)),
                        Float(time.truncatingRemainder(dividingBy: 7200)),
                        Float((time * Self.carSpeed / 150).truncatingRemainder(dividingBy: 1)), Float(sun.night)),
            clock: SIMD4(Float(clock.hour), Float(clock.sunset), 0, 0),
            legA: Self.gpu(legA, reference: reference),
            legB: Self.gpu(legB, reference: reference))
        return Frame(scene: scene, reference: reference, sweepFront: sweepFront, legA: legA, legB: legB)
    }

    private static func gpu(_ leg: Leg, reference: Double) -> LegGPU {
        // Seeds stay below 2^24 so they survive the trip through a float.
        let seed = Float((UInt32(truncatingIfNeeded: leg.index &* 2_654_435_761 &+ 977) >> 8) & 0xffff)
        return LegGPU(biome: BiomeGPU(leg.season.biome),
                      info: SIMD4(Float(leg.start - reference), seed, Float(leg.index), 0))
    }

    /// Cloud space for a point `metres` from the desktop origin: clouds drift with the wind and, being
    /// nearer the camera, slide past a little faster than the ground.
    func cloudSpace(_ metres: SIMD2<Double>) -> SIMD2<Double> {
        let p = metres + camera * 1.15 - Self.wind * time
        return SIMD2(p.x.positiveRemainder(16384), p.y.positiveRemainder(16384))
    }

    /// Space for the gusts rolling over the crops, which travel with the wind across the ground.
    func gustSpace(_ metres: SIMD2<Double>) -> SIMD2<Double> {
        let p = metres + camera - Self.wind * 2.2 * time
        return SIMD2(p.x.positiveRemainder(160 * 1024), p.y.positiveRemainder(55 * 1024))
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
