import CoreGraphics
import Foundation

/// The trains that run through a place.
public struct Railway: Sendable {
    public enum Kind: Int, Sendable {
        /// Passenger cars with windows that light up at night.
        case passenger
        /// Covered hoppers behind diesel locomotives.
        case freight
    }

    public var kind: Kind
    public var body: SIMD3<Float>
    public var stripe: SIMD3<Float>
    public var roof: SIMD3<Float>
    public var locomotive: SIMD3<Float>
    public var cars: Int
    /// Metres.
    public var carLength: Double
    public var locomotives: Int
    /// Metres per second.
    public var speed: Double
    /// Overhead line masts beside the track.
    public var electrified: Bool
    /// Chance that a line crosses each stretch of the journey over this place.
    public var chance: Double
}

/// One train run, timed so it passes while its line is on screen.
public struct TrainRun: Equatable, Sendable {
    /// Along-track position of the nose, in metres from the rail's origin.
    public var head: Double
    /// +1 running towards increasing along-track positions, -1 the other way.
    public var direction: Double
}

/// A straight-ish railway line crossing a leg at an angle, in leg-local metres.
public struct RailLine: Equatable, Sendable {
    public var origin: SIMD2<Double>
    /// Radians from east.
    public var angle: Double
    /// A gentle sideways wiggle: amplitude and wavelength in metres, and its phase.
    public var amplitude: Double
    public var wavelength: Double
    public var phase: Double

    /// The line for a leg, or nil if this stretch has none. Deterministic, so every display agrees.
    public static func line(for leg: Leg, riverX: Double, legLength: Double) -> RailLine? {
        guard let railway = leg.place.railway else { return nil }
        var random = Shuffle(seed: UInt64(leg.index) &* 0x9E3779B97F4A7C15 &+ 0x5A17)
        guard random.next() < railway.chance else { return nil }
        let y = legLength * (0.35 + 0.3 * random.next())
        let x = riverX + (random.next() - 0.5) * 360
        // 25 to 65 degrees either side of east-west, so it crosses the flight path at a slant.
        var angle = (25 + 40 * random.next()) * .pi / 180
        if random.next() < 0.5 { angle = .pi - angle }
        return RailLine(origin: SIMD2(x, y), angle: angle, amplitude: 60 + 80 * random.next(),
                        wavelength: 700 + 500 * random.next(), phase: random.next() * 2 * .pi)
    }

    /// Where along the line a world point (leg-local) projects.
    public func along(_ point: SIMD2<Double>) -> Double {
        let d = point - origin
        return d.x * cos(angle) + d.y * sin(angle)
    }

    /// Signed distance across the line, ignoring the wiggle.
    public func across(_ point: SIMD2<Double>) -> Double {
        let d = point - origin
        return -d.x * sin(angle) + d.y * cos(angle)
    }
}

extension RailLine {
    /// The train on this line at time `t`, if one is passing. `crossing` is when the middle of the screen
    /// passes over the line and `middle` the along-track position where it does; the train's nose reaches
    /// that point at that moment, so it runs through the middle of the screen.
    public func train(at t: TimeInterval, crossing: TimeInterval, middle: Double, railway: Railway,
                      seed: Int) -> TrainRun? {
        var random = Shuffle(seed: UInt64(bitPattern: Int64(seed)) &+ 0xC0FFEE)
        guard random.next() < 0.85 else { return nil }
        let direction: Double = random.next() < 0.5 ? 1 : -1
        let length = Double(railway.cars + railway.locomotives) * railway.carLength
        let elapsed = t - crossing
        guard abs(elapsed * railway.speed) < 900 + length else { return nil }
        return TrainRun(head: middle + direction * railway.speed * elapsed, direction: direction)
    }

    /// When a moving point crosses the line, found by Newton's method from its path. `path(t)` gives the
    /// point in leg-local metres; returns the time and where along the line it crosses.
    public func crossing(near t: TimeInterval, path: (TimeInterval) -> SIMD2<Double>) -> (time: TimeInterval, along: Double)? {
        var guess = t
        for _ in 0..<8 {
            let f = across(path(guess))
            let slope = across(path(guess + 1)) - f
            guard abs(slope) > 1e-6 else { return nil }
            let step = f / slope
            guess -= step
            if abs(step) < 0.01 { break }
        }
        return (guess, along(path(guess)))
    }
}

/// Birds that cross the sky now and then: skeins of geese, loose groups of egrets, circling vultures.
public struct Flock: Sendable {
    public enum Formation: Int, Sendable {
        case skein, loose, circling
    }

    public var formation: Formation
    public var count: Int
    public var color: SIMD3<Float>
    /// Half the wingspan on screen, in points.
    public var size: Double
    /// Points per second across the screen.
    public var speed: Double
    /// Metres above the ground, which sets how far and how softly the shadows fall.
    public var altitude: Double
    /// Mean minutes between appearances.
    public var interval: Double

    public static let geese = Flock(formation: .skein, count: 15, color: Biome.rgb(0x5c544c), size: 9, speed: 38,
                                    altitude: 140, interval: 9)
    public static let swans = Flock(formation: .skein, count: 9, color: Biome.rgb(0xf4f3ef), size: 11, speed: 34,
                                    altitude: 120, interval: 10)
    public static let cranes = Flock(formation: .skein, count: 13, color: Biome.rgb(0x8d8f93), size: 10.5, speed: 34,
                                     altitude: 160, interval: 10)
    public static let flamingos = Flock(formation: .skein, count: 11, color: Biome.rgb(0xf29cac), size: 10, speed: 32,
                                        altitude: 90, interval: 8)
    public static let egrets = Flock(formation: .loose, count: 5, color: Biome.rgb(0xf6f5f0), size: 8.5, speed: 24,
                                     altitude: 18, interval: 5)
    public static let rooks = Flock(formation: .loose, count: 7, color: Biome.rgb(0x2a2a2e), size: 7.5, speed: 28,
                                    altitude: 40, interval: 7)
    public static let vultures = Flock(formation: .circling, count: 5, color: Biome.rgb(0x3b332c), size: 12,
                                       speed: 0, altitude: 220, interval: 12)

    /// Which birds fly over a place in a given month.
    public static func of(_ place: Place, month: Int) -> Flock? {
        let winter = [11, 12, 1, 2, 3].contains(month)
        let migration = [3, 4, 9, 10, 11].contains(month)
        switch place.id {
        case "niigata": return winter ? .swans : .egrets
        case "punjab": return winter ? .cranes : .egrets
        case "serengeti": return .vultures
        case "normandy": return migration ? .geese : .rooks
        case "lisse": return winter || migration ? .geese : .rooks
        case "pampa": return .flamingos
        case "lapland": return [5, 9, 10].contains(month) ? .geese : [6, 7, 8].contains(month) ? .cranes : nil
        case "kansas": return winter || migration ? .geese : nil
        default: return nil
        }
    }
}

/// Where a flock is, in global desktop points.
public struct FlockSighting: Equatable, Sendable {
    public var position: SIMD2<Double>
    /// Direction of flight in radians counterclockwise from east; for circling birds, the angle round the circle.
    public var heading: Double
    public var time: TimeInterval
}

extension Flock {
    /// The flock in the sky at time `t` over `area`, if one is crossing. Each seven-minute window rolls once
    /// for a flight; flights cross from one side of the area to the other.
    public func sighting(at t: TimeInterval, area: CGRect, seed: Int) -> FlockSighting? {
        let window = 420.0
        let index = (t / window).rounded(.down)
        var random = Shuffle(seed: UInt64(bitPattern: Int64(index)) &* 0x2545F4914F6CDD1D &+ UInt64(seed))
        guard random.next() < min(window / (interval * 60), 0.95) else { return nil }
        let start = index * window + random.next() * window * 0.4
        let elapsed = t - start
        guard elapsed >= 0 else { return nil }
        let w = Double(area.width), h = Double(area.height)
        let centre = SIMD2(Double(area.midX), Double(area.midY))
        if formation == .circling {
            guard elapsed < 150 else { return nil }
            let point = centre + SIMD2((random.next() - 0.5) * w * 0.6, (random.next() - 0.5) * h * 0.5)
            return FlockSighting(position: point, heading: elapsed * 2 * .pi / 40, time: elapsed)
        }
        // Enter beyond one edge and aim through the middle half of the area.
        let angle = random.next() * 2 * .pi
        let radius = (w * w + h * h).squareRoot() * 0.5 + 120
        let entry = centre - SIMD2(cos(angle), sin(angle)) * radius
        let aim = centre + SIMD2((random.next() - 0.5) * w * 0.5, (random.next() - 0.5) * h * 0.5)
        let heading = atan2(aim.y - entry.y, aim.x - entry.x)
        let travelled = elapsed * speed
        guard travelled < radius * 2 + 200 else { return nil }
        let position = entry + SIMD2(cos(heading), sin(heading)) * travelled
        return FlockSighting(position: position, heading: heading, time: elapsed)
    }
}

/// Small deterministic random numbers.
struct Shuffle {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
