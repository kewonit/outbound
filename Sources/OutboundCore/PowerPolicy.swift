import Foundation

public enum FramePacing {
    /// A frame rate near `target` that a display shows evenly. A panel that refreshes at `fastest` shows only whole
    /// fractions of it evenly: 24 on a 60 Hz panel would alternate two and three refreshes a frame and judder. So
    /// this is the lowest fraction at or above the target (60 Hz: 30, 75 Hz: 37.5), unless that is more than half as
    /// much again, then the highest below it (50 Hz: 25). `slowest` is given for a panel that can refresh at any rate
    /// down to it for this window, like ProMotion, which then shows the target as it is.
    ///
    /// With `lowest`, the rate above is taken only if it is within a fifth of the target; further over, the one below
    /// serves as well and costs less, as long as it is still `lowest` or more (75 Hz: 25 rather than 37.5, but 60 Hz
    /// keeps 30 for a target of 24, as 20 would be too few). Every frame costs the same, so frames over the target are
    /// spent for nothing.
    public static func rate(target: Double, fastest: Double, slowest: Double? = nil, lowest: Double? = nil) -> Double {
        guard target > 0, fastest.isFinite, fastest >= 20 else { return target }
        // Panels at 59.94 or 119.88 Hz are a hair under their round rates.
        let floor = target * (1 - 1.0 / 128)
        if let slowest, slowest < fastest, target >= slowest * (1 - 1.0 / 128) { return min(target, fastest) }
        let fractions = (1...Int((fastest / target).rounded(.up)) + 1).map { fastest / Double($0) }
        let below = fractions.first { $0 < floor }
        if let above = fractions.last(where: { $0 >= floor }), above <= target * 1.5 {
            if let lowest, above > target * 1.2, let below, below >= lowest * (1 - 1.0 / 128) { return below }
            return above
        }
        return below ?? fastest
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
    /// The user's choice for running on battery.
    public var batteryMode = BatteryMode.gentle

    public enum BatteryMode: String, CaseIterable, Sendable {
        /// Keep flying at a lower frame rate.
        case gentle
        /// Hold a still painting until power is back.
        case still
    }

    public init() {}

    /// Why the wallpaper holds a still painting rather than flying, so the menu can say so.
    public enum HoldReason: Sendable {
        case lowPower
        /// The Mac is running hot.
        case heat
        /// On battery, with the choice to hold still there.
        case battery
    }

    public var holdReason: HoldReason? {
        if lowPower { return .lowPower }
        if thermal >= .serious { return .heat }
        if onBattery && batteryMode == .still { return .battery }
        return nil
    }
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
        if state.holdReason != nil {
            return PowerTier(framesPerSecond: 0, frozen: true, halfRateClouds: true)
        }
        // An even 30 a second, as the site's videos run, keeps the slow pan smooth; on battery 24, which the
        // built-in display also shows evenly. The bird chasing the cursor wants more, but it has its own small
        // layer, so only that runs faster.
        var fps: Double = state.onBattery ? 24 : 30
        if state.thermal == .fair { fps = state.onBattery ? 20 : 24 }
        return PowerTier(framesPerSecond: fps, frozen: false, halfRateClouds: state.onBattery,
                         birdFramesPerSecond: state.onBattery || state.thermal == .fair ? 30 : 60)
    }
}

/// How much ground painting that can wait, like a repaint wave, every display together may do. Painting is the heavy
/// part of a frame, and all displays share one GPU; what it costs is learned from frames as they finish, so a slow
/// GPU spreads the same work over more frames instead of missing them.
public struct PaintBudget: Sendable {
    /// GPU time per thirtieth of a second that painting which can wait may take.
    public var milliseconds: Double
    /// What painting a million texels costs on this GPU, in milliseconds.
    public private(set) var costPerMillion: Double
    private var saved = 0.0
    private var savedAt: Double?

    public init(milliseconds: Double = 4, costPerMillion: Double = 15) {
        self.milliseconds = milliseconds
        self.costPerMillion = costPerMillion
    }

    /// Texels per second.
    private var rate: Double { milliseconds * 30 / costPerMillion * 1e6 }

    /// Up to `wanted` texels to paint now, at `time` in seconds. What isn't taken is kept, but never more than one
    /// thirtieth of a second's worth, so it can't build up into a burst.
    public mutating func take(_ wanted: Int, at time: Double) -> Int {
        refill(at: time)
        let granted = min(Double(max(wanted, 0)), max(saved, 0))
        saved -= granted
        return Int(granted)
    }

    /// Painting that couldn't wait, like newly revealed rows, still counts against what can.
    public mutating func spend(_ texels: Int, at time: Double) {
        refill(at: time)
        saved = max(saved - Double(texels), -rate / 30)
    }

    /// A frame finished: `milliseconds` of its GPU time went on painting `texels`.
    public mutating func learn(milliseconds: Double, painted texels: Int) {
        guard texels >= 50_000, milliseconds.isFinite else { return }
        let sample = min(max(milliseconds / (Double(texels) / 1e6), 1), 400)
        costPerMillion += (sample - costPerMillion) * 0.25
    }

    /// The world went back `seconds`, as it does to a painting's moment as the Mac locks, so frames now ask from that
    /// far back and the budget refills from there.
    public mutating func rewind(by seconds: Double) {
        savedAt = savedAt.map { $0 - seconds }
    }

    /// Displays a moment apart may ask in any order, so time only ever moves the budget forward.
    private mutating func refill(at time: Double) {
        guard let savedAt else {
            saved = rate / 30
            savedAt = time
            return
        }
        guard time > savedAt else { return }
        saved = min(saved + (time - savedAt) * rate, rate / 30)
        self.savedAt = time
    }
}
