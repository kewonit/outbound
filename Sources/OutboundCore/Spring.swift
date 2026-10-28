import Foundation

/// Daniel Holden's exact critically damped spring: eases a value towards a goal without overshoot,
/// and gives the same motion whatever the frame rate.
public struct Spring: Codable, Sendable {
    public var value: SIMD2<Double>
    public var velocity = SIMD2<Double>.zero
    /// Time to close half the distance to the goal.
    public var halflife: Double

    public init(_ value: SIMD2<Double>, halflife: Double) {
        self.value = value
        self.halflife = halflife
    }

    public mutating func step(towards goal: SIMD2<Double>, dt: Double) {
        let y = (4 * log(2.0)) / (halflife + 1e-5) / 2
        let j0 = value - goal
        let j1 = velocity + j0 * y
        let decay = exp(-y * dt)
        value = (j0 + j1 * dt) * decay + goal
        velocity = (velocity - j1 * (y * dt)) * decay
    }
}
