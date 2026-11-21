import Combine
import Foundation
import OutboundCore

/// The user's choices, kept in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    enum Pace: String, CaseIterable, Identifiable {
        case slow, gentle, brisk
        var id: Self { self }
        var title: String {
            switch self {
            case .slow: String(localized: "Slow")
            case .gentle: String(localized: "Medium")
            case .brisk: String(localized: "Fast")
            }
        }
        /// Metres per second over the ground.
        var speed: Double {
            switch self {
            case .slow: 1.4
            case .gentle: 2.2
            case .brisk: 3.3
            }
        }
    }

    /// Minutes over each place, or none to stay over the one in view. Six and twelve, offered once, are not any more.
    /// The menu offers them as when to go on to the next place.
    enum Stay: Int, CaseIterable, Identifiable {
        case short = 20, long = 30, hour = 60, forever = 0
        var id: Self { self }
        var title: String {
            switch self {
            case .short: String(localized: "After 20 Minutes")
            case .long: String(localized: "After 30 Minutes")
            case .hour: String(localized: "After an Hour")
            case .forever: String(localized: "Never")
            }
        }
    }

    /// How long nobody uses the Mac before it holds still, in minutes, or never.
    enum Away: Int, CaseIterable, Identifiable {
        case two = 2, five = 5, fifteen = 15, half = 30, never = 0
        var id: Self { self }
        var title: String {
            switch self {
            case .two: String(localized: "After 2 Minutes")
            case .five: String(localized: "After 5 Minutes")
            case .fifteen: String(localized: "After 15 Minutes")
            case .half: String(localized: "After 30 Minutes")
            // Its own key: the Next Place menu's Never is translated as staying put.
            case .never: String(localized: "Never (away)", defaultValue: "Never")
            }
        }
        /// Seconds without anyone at the Mac before it holds still, or nil.
        var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue * 60) }
    }

    // Each is saved only when it changes, so what is saved is what someone chose, and a default changed later still
    // reaches everyone who never did. Versions before 1.6 saved every one whenever any changed, and as they quit.
    @Published var light: World.Light { didSet { defaults.set(light.rawValue, forKey: "light") } }
    @Published var followsCalendar: Bool { didSet { defaults.set(followsCalendar, forKey: "followsCalendar") } }
    @Published var pace: Pace { didSet { defaults.set(pace.rawValue, forKey: "flightPace") } }
    @Published var stay: Stay { didSet { defaults.set(stay.rawValue, forKey: "stay") } }
    @Published var batteryMode: PowerState.BatteryMode {
        didSet { defaults.set(batteryMode.rawValue, forKey: "batteryMode") }
    }
    /// Keep a painting of the current view as the desktop picture, so the lock screen shows it too.
    @Published var matchingStill: Bool { didSet { defaults.set(matchingStill, forKey: "matchingStill") } }
    /// Hold still after a while without anyone at the Mac: whether at all is kept where it always was, under
    /// `restsWhenAway`, and how long under `restAfter`.
    @Published var away: Away {
        didSet {
            if (away == .never) != (oldValue == .never) { defaults.set(away != .never, forKey: "restsWhenAway") }
            if away != .never { defaults.set(away.rawValue, forKey: "restAfter") }
        }
    }
    /// Hold the flight while every display's desktop is hidden, as by full-screen apps, so nothing is drawn that nobody
    /// can see: on by default. Off, it flies on unseen, at the 24 frames a second of a covered desktop, and the view
    /// has moved on when the desktop comes back.
    @Published var pausesWhenHidden: Bool { didSet { defaults.set(pausesWhenHidden, forKey: "holdsWhenHidden") } }
    /// The pale dry-brush border round the painting. Off until it is asked for.
    @Published var paperEdge: Bool { didSet { defaults.set(paperEdge, forKey: "paperBorder") } }
    /// The place's name in the corner of the desktop. On until it is turned off.
    @Published var showsPlaceName: Bool { didSet { defaults.set(showsPlaceName, forKey: "showsPlaceName") } }
    /// The land comes straight down the screen, with no drift from side to side.
    @Published var fliesStraight: Bool { didSet { defaults.set(fliesStraight, forKey: "fliesStraight") } }
    /// The gull over the desktop, and in the painting of it.
    @Published var showsBird: Bool { didSet { defaults.set(showsBird, forKey: "showsGull") } }
    /// The gull chases the pointer for a while after it moves over the desktop.
    @Published var followsPointer: Bool { didSet { defaults.set(followsPointer, forKey: "followsPointer") } }
    /// Places left out of the round, by id: what is left out rather than what is in, so places added later join it.
    @Published var skippedPlaces: Set<String> { didSet { defaults.set(skippedPlaces.sorted(), forKey: "skippedPlaces") } }
    /// Moves on to a place picked at random rather than the next one.
    @Published var shufflesPlaces: Bool { didSet { defaults.set(shufflesPlaces, forKey: "shufflesPlaces") } }
    /// The order the flight goes through the places in, by id, every place once. The usual order isn't saved, so it
    /// stays Outbound's own, with any places added later where they belong in it.
    @Published var placeOrder: [String] {
        didSet {
            // Set again here, it isn't observed again.
            let ordered = Self.ordered(placeOrder)
            if ordered != placeOrder { placeOrder = ordered }
            if placeOrder == Self.usualOrder { defaults.removeObject(forKey: "placeOrder") } else {
                defaults.set(placeOrder, forKey: "placeOrder")
            }
        }
    }

    static var usualOrder: [String] { Place.all.map(\.id) }

    /// Every place once, in the order given: places no longer painted are let go, and any not in it, as one added in an
    /// update since it was saved, come at the end, in Outbound's own order.
    static func ordered(_ ids: [String]) -> [String] {
        let known = Set(usualOrder)
        var seen = Set<String>()
        let kept = ids.filter { known.contains($0) && seen.insert($0).inserted }
        return kept + usualOrder.filter { !seen.contains($0) }
    }
    /// The place to start from next launch.
    @Published var lastPlace: String { didSet { defaults.set(lastPlace, forKey: "lastPlace") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        light = World.Light(rawValue: defaults.string(forKey: "light") ?? "") ?? .alwaysDay
        followsCalendar = defaults.object(forKey: "followsCalendar") as? Bool ?? false
        // Kept under a new name since every pace slowed down and Slow became the default: everyone starts there once,
        // whatever they flew at before, and can choose again.
        pace = Pace(rawValue: defaults.string(forKey: "flightPace") ?? "") ?? .slow
        stay = (defaults.object(forKey: "stay") as? Int).flatMap(Stay.init(rawValue:)) ?? .short
        batteryMode = PowerState.BatteryMode(rawValue: defaults.string(forKey: "batteryMode") ?? "") ?? .gentle
        matchingStill = defaults.object(forKey: "matchingStill") as? Bool ?? true
        away = defaults.object(forKey: "restsWhenAway") as? Bool == false ? .never
            : (defaults.object(forKey: "restAfter") as? Int).flatMap(Away.init(rawValue:)).flatMap { $0 == .never ? nil : $0 }
            ?? .five
        // Kept under a new name since it came on by default. 1.5 saved it as off for everyone as it quit, so off there
        // can't be told from never chosen; on there was chosen, and is on here too.
        pausesWhenHidden = defaults.object(forKey: "holdsWhenHidden") as? Bool ?? true
        // Kept under a new name since the border went off by default: the old one was saved as on for everyone who
        // had run Outbound by then, whether they asked for it or not.
        paperEdge = defaults.object(forKey: "paperBorder") as? Bool ?? false
        showsPlaceName = defaults.object(forKey: "showsPlaceName") as? Bool ?? true
        fliesStraight = defaults.object(forKey: "fliesStraight") as? Bool ?? false
        showsBird = defaults.object(forKey: "showsGull") as? Bool ?? true
        followsPointer = defaults.object(forKey: "followsPointer") as? Bool ?? true
        skippedPlaces = Set(defaults.stringArray(forKey: "skippedPlaces") ?? [])
        shufflesPlaces = defaults.object(forKey: "shufflesPlaces") as? Bool ?? false
        placeOrder = Self.ordered(defaults.stringArray(forKey: "placeOrder") ?? [])
        lastPlace = defaults.string(forKey: "lastPlace") ?? Place.first.id
        // What the old names hold says nothing about what anyone chose.
        defaults.removeObject(forKey: "pausesWhenHidden")
        defaults.removeObject(forKey: "paperEdge")
        defaults.removeObject(forKey: "pace")
    }
}

extension World.Light {
    var title: String {
        switch self {
        case .yourTime: String(localized: "Follow My Clock")
        case .placeTime: String(localized: "Local Time There")
        case .alwaysDay: String(localized: "Always Daytime")
        }
    }
}

extension PowerState.BatteryMode {
    var title: String {
        switch self {
        case .gentle: String(localized: "Keep flying, gently")
        case .still: String(localized: "Hold a still painting")
        }
    }
}
