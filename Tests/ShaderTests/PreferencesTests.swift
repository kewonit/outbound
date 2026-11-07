import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// Settings that changed their default reach everyone who never asked for the old one, and the choices someone made
/// come through an update, except where a change was meant for everyone.
@MainActor
@Suite
struct PreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func theBorderStartsOffAndHoldingWhenHiddenOn() throws {
        try withDefaults { defaults in
            // A first launch.
            #expect(Preferences(defaults: defaults).pausesWhenHidden)
            #expect(!Preferences(defaults: defaults).paperEdge)
            // As versions before saved them, for everyone: the border on, and holding while hidden off.
            defaults.set(true, forKey: "paperEdge")
            defaults.set(false, forKey: "pausesWhenHidden")
            let preferences = Preferences(defaults: defaults)
            #expect(!preferences.paperEdge)
            #expect(preferences.pausesWhenHidden)
            // The old names are let go of.
            #expect(defaults.object(forKey: "paperEdge") == nil)
            #expect(defaults.object(forKey: "pausesWhenHidden") == nil)

            // Another setting changing, or the place moving on, saves only that one.
            preferences.pace = .brisk
            preferences.lastPlace = "lapland"
            #expect(defaults.object(forKey: "holdsWhenHidden") == nil)
            #expect(defaults.object(forKey: "paperBorder") == nil)

            // Turned off, it stays off; on again, it stays on. Asked for, the border stays on.
            preferences.pausesWhenHidden = false
            #expect(!Preferences(defaults: defaults).pausesWhenHidden)
            preferences.pausesWhenHidden = true
            #expect(Preferences(defaults: defaults).pausesWhenHidden)
            preferences.paperEdge = true
            #expect(Preferences(defaults: defaults).paperEdge)
        }
    }

    @Test func everyoneStartsOnSlowOnceAndCanChooseAgain() throws {
        try withDefaults { defaults in
            // A first launch.
            #expect(Preferences(defaults: defaults).pace == .slow)
            // Coming from a version with faster paces, whichever was saved.
            for saved in ["slow", "gentle", "brisk"] {
                defaults.removeObject(forKey: "flightPace")
                defaults.set(saved, forKey: "pace")
                #expect(Preferences(defaults: defaults).pace == .slow)
                #expect(defaults.object(forKey: "pace") == nil)
            }
            // What they choose now stays.
            Preferences(defaults: defaults).pace = .brisk
            #expect(Preferences(defaults: defaults).pace == .brisk)
        }
    }

    @Test(arguments: [6, 12])
    func stayOfMinutesNoLongerOfferedBecomesTwenty(minutes: Int) throws {
        try withDefaults { defaults in
            defaults.set(minutes, forKey: "stay")
            #expect(Preferences(defaults: defaults).stay == .short)
        }
    }

    @Test func holdingWhenHiddenChosenIn15StaysOn() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "pausesWhenHidden")
            #expect(Preferences(defaults: defaults).pausesWhenHidden)
        }
    }

    /// Everything 1.5 saved as it quit, the choices other than the pace and holding while hidden come through as they were.
    @Test func anUpdateFrom15KeepsEveryOtherChoice() throws {
        try withDefaults { defaults in
            let saved: [String: Any] = [
                "light": "yourTime", "followsCalendar": true, "pace": "brisk", "stay": 30, "batteryMode": "still",
                "matchingStill": false, "restsWhenAway": false, "pausesWhenHidden": false, "paperBorder": true,
                "lastPlace": "niigata",
            ]
            saved.forEach { defaults.set($1, forKey: $0) }
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.light == .yourTime)
            #expect(preferences.followsCalendar)
            #expect(preferences.pace == .slow)
            #expect(preferences.stay == .long)
            #expect(preferences.batteryMode == .still)
            #expect(!preferences.matchingStill)
            #expect(!preferences.restsWhenAway)
            #expect(preferences.paperEdge)
            #expect(preferences.lastPlace == "niigata")
            #expect(preferences.pausesWhenHidden)
        }
    }
}
