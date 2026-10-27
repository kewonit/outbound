import Foundation

/// The gentle start that keeps the flight from jumping into motion after it was held.
public enum Easing {
    /// How far behind its usual schedule the flight is, `elapsed` seconds after it starts again from still, when it
    /// gathers speed over `length` seconds instead of setting off at full pace. It grows from nothing to half of
    /// `length`, where it stays.
    public static func rampLag(elapsed: Double, length: Double) -> Double {
        guard length > 0, elapsed > 0 else { return 0 }
        guard elapsed < length else { return length / 2 }
        // The time flown is the integral of smoothstep, p³ − p⁴/2 of the length.
        let p = elapsed / length
        return elapsed - length * (p * p * p - p * p * p * p / 2)
    }
}
