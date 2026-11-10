import CoreGraphics
import Foundation

/// The gull. It lives in global desktop points, so it can fly from one display to another, follows the cursor while it
/// is moving and otherwise glides about on its own. It flies as a bird does, along its heading: it can only roll into a
/// turn and round it, so wherever it wants to go it gets there in a curve.
public struct Bird: Codable, Sendable {
    public static let cruise = 36.0
    public static let topSpeed = 95.0
    public static let slowest = 20.0
    /// How wide it circles a still cursor.
    public static let orbit = 90.0
    /// The sharpest it can turn, in radians a second.
    public static let sharpestTurn = 1.15

    public private(set) var position: SIMD2<Double>
    public private(set) var velocity: SIMD2<Double>
    /// Direction of travel in radians, counterclockwise from east.
    public private(set) var heading: Double
    /// -1 banking left to 1 banking right.
    public private(set) var bank = 0.0
    /// 0 with wings drawn in to 1 fully spread.
    public private(set) var wings = 1.0

    /// How fast it is turning, in radians a second, which it eases into and out of.
    private var turning = 0.0
    private var banking = Spring(SIMD2<Double>(0, 0), halflife: 0.35)
    private var beats = 0.0
    private var flapPhase = 0.0
    private var gliding = 0.0
    private var orbitDirection = 1.0

    public init(at position: SIMD2<Double>) {
        self.position = position
        velocity = SIMD2(Self.cruise, 0)
        heading = 0
    }

    private enum CodingKeys: String, CodingKey {
        case position, velocity, heading, bank, wings, turning, banking, beats, flapPhase, gliding, orbitDirection
    }

    /// A bird saved by a version that flew it differently comes back as it was, flying straight on.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        position = try saved.decode(SIMD2<Double>.self, forKey: .position)
        velocity = try saved.decode(SIMD2<Double>.self, forKey: .velocity)
        heading = try saved.decode(Double.self, forKey: .heading)
        bank = try saved.decode(Double.self, forKey: .bank)
        wings = try saved.decode(Double.self, forKey: .wings)
        turning = try saved.decodeIfPresent(Double.self, forKey: .turning) ?? 0
        banking = try saved.decode(Spring.self, forKey: .banking)
        flapPhase = try saved.decode(Double.self, forKey: .flapPhase)
        gliding = try saved.decode(Double.self, forKey: .gliding)
        orbitDirection = try saved.decode(Double.self, forKey: .orbitDirection)
        if let saved = try saved.decodeIfPresent(Double.self, forKey: .beats) {
            beats = saved
        } else if wings < 1 {
            // Saved part way through an older beat: it finishes this one, opening its wings from where they were.
            beats = 1
            flapPhase = 2 * .pi - acos(max(-1, min(1, (wings - 0.55) / 0.45)))
        }
    }

    /// Where the bird drifts when nobody is pointing: a slow loop around the middle of `area`. Over a big display the
    /// loop is gone round more slowly, so it never moves faster than the gliding bird can follow.
    public static func wander(in area: CGRect, time: Double) -> SIMD2<Double> {
        // The loop's fastest, in points a second, from the sizes and rates below: each way's fastest, together.
        let across = 0.0196 * Double(area.width), up = 0.0137 * Double(area.height)
        let fastest = (across * across + up * up).squareRoot()
        let time = time * min(1, wanderPace / max(fastest, 1))
        let x = Double(area.midX) + Double(area.width) * 0.3 * sin(time * 0.036) + Double(area.width) * 0.08 * sin(time * 0.11)
        let y = Double(area.midY) + Double(area.height) * 0.26 * sin(time * 0.027 + 1.1)
            + Double(area.height) * 0.07 * cos(time * 0.095)
        return SIMD2(x, y)
    }

    /// The fastest the wander loop goes: a little under cruising speed, which a laptop's display already keeps to.
    public static let wanderPace = 33.0

    /// Puts the bird somewhere for a still picture.
    public mutating func pose(at position: SIMD2<Double>, heading: Double, wings: Double = 1) {
        self.position = position
        self.heading = heading
        self.wings = wings
        bank = 0
        turning = 0
        velocity = SIMD2(cos(heading), sin(heading)) * Self.cruise
    }

    /// Flies on for `dt` towards `target`, making haste if `hurrying`, and otherwise at its own easy pace.
    public mutating func step(dt rawDt: Double, towards target: SIMD2<Double>, hurrying: Bool = true) {
        let dt = min(max(rawDt, 0), 0.25)
        guard dt > 0 else { return }
        let offset = target - position
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        let bearing = distance > 1e-6 ? atan2(offset.y, offset.x) : heading

        // It steers for the edge of a circle round the target, on whichever side is less of a turn. From far off that
        // is almost straight at it, closer in it leans round, and at the edge it flies along it, so it comes in on a
        // curve and goes straight into circling, and from inside the circle it leans out again.
        if distance > Self.orbit * 2 { orbitDirection = sin(heading - bearing) >= 0 ? 1 : -1 }
        let lean = distance > Self.orbit ? asin(Self.orbit / distance) : .pi / 2 + 1 - distance / Self.orbit
        let error = Self.shortestTurn(from: heading, to: bearing + lean * orbitDirection)
        let goal = max(-Self.sharpestTurn, min(Self.sharpestTurn, error * 1.8))
        turning += (goal - turning) * (1 - exp(-dt / 0.4))
        heading = atan2(sin(heading + turning * dt), cos(heading + turning * dt))

        // Faster the further it has to go, and a little slower round a hard turn, so it never quite stops in the air.
        let far = hurrying ? max(distance - Self.orbit, 0) * 0.6 : 0
        let pace = min(Self.cruise + far, Self.topSpeed) * (1 - 0.3 * abs(turning) / Self.sharpestTurn)
        var speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        speed += (pace - speed) * (1 - exp(-dt / 0.9))
        speed = max(speed, Self.slowest)
        velocity = SIMD2(cos(heading), sin(heading)) * speed
        position += velocity * dt

        banking.step(towards: SIMD2(-0.9 * turning / Self.sharpestTurn, 0), dt: dt)
        bank = banking.value.x

        // A few slow beats to gather speed, or now and then after a long glide; otherwise it holds its wings out. Whole
        // beats, so they end with the wings open.
        gliding += dt
        if beats <= 0 && ((pace > speed + 14 && gliding > 6) || gliding > 14) {
            beats = 3
            flapPhase = 0
            gliding = 0
        }
        if beats > 0 {
            flapPhase += dt * 2 * .pi * 2
            if flapPhase >= beats * 2 * .pi {
                beats = 0
                wings = 1
            } else {
                wings = 0.55 + 0.45 * cos(flapPhase)
            }
        }
    }

    private static func shortestTurn(from a: Double, to b: Double) -> Double {
        atan2(sin(b - a), cos(b - a))
    }

    /// Where the bird is and how it holds itself, which is all a picture of it needs.
    public struct Pose: Equatable, Sendable {
        public var position: SIMD2<Double>
        public var heading: Double
        public var bank: Double
        public var wings: Double

        public init(position: SIMD2<Double>, heading: Double, bank: Double, wings: Double) {
            self.position = position
            self.heading = heading
            self.bank = bank
            self.wings = wings
        }

        /// The pose a fraction of the way from `a` to `b`, turning the short way round.
        public static func between(_ a: Pose, _ b: Pose, _ f: Double) -> Pose {
            let turn = atan2(sin(b.heading - a.heading), cos(b.heading - a.heading))
            return Pose(position: a.position + (b.position - a.position) * f, heading: a.heading + turn * f,
                        bank: a.bank + (b.bank - a.bank) * f, wings: a.wings + (b.wings - a.wings) * f)
        }
    }

    public var pose: Pose {
        Pose(position: position, heading: heading, bank: bank, wings: wings)
    }
}

/// The bird's last few poses, so every display and the bird's own layer can each draw it at the moment they show,
/// though it is stepped by whichever of them asks first.
public struct BirdTrail: Sendable {
    private var poses: [(time: Double, pose: Bird.Pose)]
    private static let kept = 12

    public init(_ pose: Bird.Pose, at time: Double) {
        poses = [(time, pose)]
    }

    /// Adds the bird as it is at `time`, which never goes back.
    public mutating func record(_ pose: Bird.Pose, at time: Double) {
        if let last = poses.last, time <= last.time {
            poses[poses.count - 1] = (last.time, pose)
        } else {
            poses.append((time, pose))
        }
        if poses.count > Self.kept { poses.removeFirst(poses.count - Self.kept) }
    }

    /// Starts again from a pose, as when the bird is placed for a picture.
    public mutating func reset(to pose: Bird.Pose, at time: Double) {
        poses = [(time, pose)]
    }

    /// The bird at `time`, between the poses either side, or the nearest one beyond the trail's ends.
    public func pose(at time: Double) -> Bird.Pose {
        guard let last = poses.last else { fatalError("A trail always has a pose") }
        if time >= last.time { return last.pose }
        guard let after = poses.firstIndex(where: { $0.time > time }), after > 0 else { return poses[0].pose }
        let a = poses[after - 1], b = poses[after]
        return Bird.Pose.between(a.pose, b.pose, (time - a.time) / (b.time - a.time))
    }
}
