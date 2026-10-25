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

    let journey: Journey
    private(set) var time: TimeInterval
    /// Union of every display in global points, so the land is decided far enough ahead.
    var desktop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// World x the river meanders around.
    var riverX = 400.0
    var cloudCover = 0.42
    /// Bumped when something changes that is baked into the ground, so every display repaints it.
    private(set) var revision = 0

    init(place: Place, time: TimeInterval, date: Date = .now) {
        self.time = time
        journey = Journey(start: place, time: time, date: date, speed: 6.5, legLength: 6.5 * 60 * 12)
    }

    func advance(to t: TimeInterval) {
        guard t > time else { return }
        time = t
        let camera = self.camera
        journey.extend(through: camera.y + Double(desktop.maxY) * Self.metresPerPoint + 1500,
                       behind: camera.y + Double(desktop.minY) * Self.metresPerPoint - 1500)
    }

    func repaint() {
        revision += 1
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
        /// A Fly To repaint is under way, so cached ground goes stale every frame.
        var sweeping: Bool
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
        var sweeping = false
        if legA.index != legB.index {
            boundary = legB.start - reference
            if let start = legB.sweepStart {
                let progress = (time - start) / Journey.sweepDuration
                if progress < 1 {
                    sweep = max(progress, 0)
                    sweeping = true
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
        let toSun = simd_normalize(SIMD2<Float>(-0.62, 0.78))

        let scene = SceneGPU(
            river: river,
            road: SIMD4(Float(riverX), Float(Self.roadOffset), phase(Self.roadWave, 0.8), crossPhase),
            sun: SIMD4(toSun.x, toSun.y, 0.85, 0.85),
            light: SIMD4(1.0, 0.995, 0.985, 1.0),
            morph: SIMD4(Float(boundary), Float(length), Float(sweep), Float(top - legB.start)),
            time: SIMD4(Float(time.truncatingRemainder(dividingBy: 3600)),
                        Float(time.truncatingRemainder(dividingBy: 7200)),
                        Float((time * Self.carSpeed / 150).truncatingRemainder(dividingBy: 1)), 0),
            legA: Self.gpu(legA, reference: reference),
            legB: Self.gpu(legB, reference: reference))
        return Frame(scene: scene, reference: reference, sweeping: sweeping)
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
