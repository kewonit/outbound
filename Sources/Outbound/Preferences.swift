import Combine
import Foundation
import OutboundCore

/// The user's choices, kept in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    enum Pace: String, CaseIterable, Identifiable {
        case slow, gentle, brisk
        var id: Self { self }
        var title: String { rawValue.capitalized }
        /// Metres per second over the ground.
        var speed: Double {
            switch self {
            case .slow: 4.2
            case .gentle: 6.5
            case .brisk: 10
            }
        }
    }

    enum Stay: Int, CaseIterable, Identifiable {
        case short = 6, medium = 12, long = 30, hour = 60
        var id: Self { self }
        var title: String { self == .hour ? "An hour" : "\(rawValue) minutes" }
    }

    @Published var light: World.Light { didSet { save() } }
    @Published var followsCalendar: Bool { didSet { save() } }
    @Published var pace: Pace { didSet { save() } }
    @Published var stay: Stay { didSet { save() } }
    @Published var batteryMode: PowerState.BatteryMode { didSet { save() } }
    /// Show a painting of the current view on the lock screen, as the desktop picture while the Mac is locked.
    @Published var matchingStill: Bool { didSet { save() } }
    /// Hold still after five minutes without anyone at the Mac.
    @Published var restsWhenAway: Bool { didSet { save() } }
    /// The place to start from next launch.
    @Published var lastPlace: String { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        light = World.Light(rawValue: defaults.string(forKey: "light") ?? "") ?? .yourTime
        followsCalendar = defaults.object(forKey: "followsCalendar") as? Bool ?? true
        pace = Pace(rawValue: defaults.string(forKey: "pace") ?? "") ?? .gentle
        stay = Stay(rawValue: defaults.integer(forKey: "stay")) ?? .medium
        batteryMode = PowerState.BatteryMode(rawValue: defaults.string(forKey: "batteryMode") ?? "") ?? .gentle
        matchingStill = defaults.object(forKey: "matchingStill") as? Bool ?? true
        restsWhenAway = defaults.object(forKey: "restsWhenAway") as? Bool ?? true
        lastPlace = defaults.string(forKey: "lastPlace") ?? Place.first.id
    }

    private func save() {
        defaults.set(light.rawValue, forKey: "light")
        defaults.set(followsCalendar, forKey: "followsCalendar")
        defaults.set(pace.rawValue, forKey: "pace")
        defaults.set(stay.rawValue, forKey: "stay")
        defaults.set(batteryMode.rawValue, forKey: "batteryMode")
        defaults.set(matchingStill, forKey: "matchingStill")
        defaults.set(restsWhenAway, forKey: "restsWhenAway")
        defaults.set(lastPlace, forKey: "lastPlace")
    }
}

extension World.Light {
    var title: String {
        switch self {
        case .yourTime: "Follows your clock"
        case .placeTime: "The place's own time"
        case .alwaysDay: "Always daytime"
        }
    }
}

extension PowerState.BatteryMode {
    var title: String {
        switch self {
        case .gentle: "Keep flying, gently"
        case .still: "Hold a still painting"
        }
    }
}
