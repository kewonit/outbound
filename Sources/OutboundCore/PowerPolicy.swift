import Foundation

public enum FramePacing {
    /// The frame rate nearest `target` that the display can show evenly. Fixed-rate panels only show whole
    /// fractions of their refresh: 24 or 30 on a 75 Hz panel would alternate between refreshes per frame and
    /// judder, while 25 is exactly every third.
    public static func rate(target: Double, refresh: Double) -> Double {
        guard refresh > 0 else { return target }
        // ProMotion panels pace any rate down to 24 themselves.
        if refresh >= 120 { return min(target, refresh) }
        let divisor = (refresh / target).rounded()
        return refresh / max(divisor, 1)
    }
}

/// How hard the wallpaper may work, from what the Mac is doing.
public struct PowerState: Equatable, Sendable {
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public var onBattery = false
    public var lowPower = false
    public var thermal = Thermal.nominal
    /// The bird is chasing the cursor, which wants smoother motion for a while.
    public var birdEngaged = false
    /// The user's choice for running on battery.
    public var batteryMode = BatteryMode.gentle

    public enum BatteryMode: String, CaseIterable, Sendable {
        /// Keep flying at a lower frame rate.
        case gentle
        /// Hold a still painting until power is back.
        case still
    }

    public init() {}
}

public struct PowerTier: Equatable, Sendable {
    /// Frames per second the wallpaper asks for, before fitting it to the display.
    public var framesPerSecond: Double
    /// Hold the last frame instead of animating.
    public var frozen: Bool
    /// Repaint the clouds only every other frame.
    public var halfRateClouds: Bool
    /// The bird has its own small layer, which runs faster while it chases the cursor.
    public var birdFramesPerSecond: Double = 60

    public static func choose(_ state: PowerState) -> PowerTier {
        if state.lowPower || state.thermal >= .serious {
            return PowerTier(framesPerSecond: 0, frozen: true, halfRateClouds: true)
        }
        if state.onBattery && state.batteryMode == .still {
            return PowerTier(framesPerSecond: 0, frozen: true, halfRateClouds: true)
        }
        // A slow pan moves about a pixel a frame at 24, which bilinear sampling keeps smooth. The bird chasing the
        // cursor wants more, but it has its own small layer, so only that runs faster.
        var fps: Double = state.onBattery ? 15 : 24
        if state.thermal == .fair { fps = state.onBattery ? 12 : 20 }
        return PowerTier(framesPerSecond: fps, frozen: false, halfRateClouds: state.onBattery,
                         birdFramesPerSecond: state.onBattery || state.thermal == .fair ? 30 : 60)
    }
}
