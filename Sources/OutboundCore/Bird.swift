import CoreGraphics
import Foundation

/// The white bird. It lives in global desktop points, so it can fly from one display to another,
/// chases the cursor while it is moving and otherwise glides about on its own.
public struct Bird: Sendable {
    public static let cruise = 70.0
    public static let topSpeed = 175.0
    public static let slowest = 34.0
    /// How close it circles a still cursor.
    public static let orbit = 64.0

    public private(set) var position: SIMD2<Double>
    public private(set) var velocity: SIMD2<Double>
    /// Direction of travel in radians, counterclockwise from east.
    public private(set) var heading: Double
    /// -1 banking left to 1 banking right.
    public private(set) var bank = 0.0
    /// 0 with wings drawn in to 1 fully spread.
    public private(set) var wings = 1.0

    private var steer: Spring
    private var banking = Spring(SIMD2<Double>(0, 0), halflife: 0.35)
    private var flapping = 0.0
    private var flapPhase = 0.0
    private var gliding = 0.0
    private var orbitDirection = 1.0

    public init(at position: SIMD2<Double>) {
        self.position = position
        velocity = SIMD2(Self.cruise, 0)
        heading = 0
        steer = Spring(velocity, halflife: 0.45)
    }

    /// Where the bird drifts when nobody is pointing: a slow loop around the middle of `area`.
    public static func wander(in area: CGRect, time: Double) -> SIMD2<Double> {
        let x = Double(area.midX) + Double(area.width) * 0.3 * sin(time * 0.071) + Double(area.width) * 0.08 * sin(time * 0.23)
        let y = Double(area.midY) + Double(area.height) * 0.26 * sin(time * 0.053 + 1.1)
            + Double(area.height) * 0.07 * cos(time * 0.19)
        return SIMD2(x, y)
    }

    /// Puts the bird somewhere for a still picture.
    public mutating func pose(at position: SIMD2<Double>, heading: Double, wings: Double = 1) {
        self.position = position
        self.heading = heading
        self.wings = wings
        bank = 0
        velocity = SIMD2(cos(heading), sin(heading)) * Self.cruise
        steer.value = velocity
    }

    public mutating func step(dt rawDt: Double, towards target: SIMD2<Double>) {
        let dt = min(max(rawDt, 0), 0.25)
        guard dt > 0 else { return }
        let offset = target - position
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        let direction = distance > 1e-6 ? offset / distance : SIMD2(cos(heading), sin(heading))

        // Arrive from afar, then circle instead of hovering, as birds do.
        var desired: SIMD2<Double>
        if distance > Self.orbit * 1.8 {
            let speed = min(Self.topSpeed, max(Self.cruise * 0.8, distance * 0.9))
            desired = direction * speed
            orbitDirection = cross(SIMD2(cos(heading), sin(heading)), direction) >= 0 ? 1 : -1
        } else {
            let tangent = SIMD2(-direction.y, direction.x) * orbitDirection
            desired = tangent * Self.cruise + direction * (distance - Self.orbit) * 0.9
        }
        steer.step(towards: desired, dt: dt)
        var v = steer.value
        var speed = (v.x * v.x + v.y * v.y).squareRoot()
        if speed < Self.slowest {
            // A bird never stops in the air.
            v = (speed > 1e-6 ? v / speed : SIMD2(cos(heading), sin(heading))) * Self.slowest
            speed = Self.slowest
            steer.value = v
        }
        velocity = v
        position += v * dt

        let newHeading = atan2(v.y, v.x)
        var turn = newHeading - heading
        turn = atan2(sin(turn), cos(turn))
        heading = newHeading
        banking.step(towards: SIMD2(max(-1, min(1, -turn / dt * 0.45)), 0), dt: dt)
        bank = banking.value.x

        // Flap to speed up, or after a long glide; otherwise hold the wings out.
        let needsLift = (desired.x * desired.x + desired.y * desired.y).squareRoot() > speed + 25
        gliding += dt
        if flapping <= 0 && (needsLift || gliding > 6) {
            flapping = 1.1
            gliding = 0
        }
        if flapping > 0 {
            flapping -= dt
            flapPhase += dt * 2 * .pi * 3.2
            wings = 0.55 + 0.45 * cos(flapPhase)
        } else {
            flapPhase = 0
            wings += (1 - wings) * min(1, dt * 6)
        }
    }

    private func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }
}
