import Foundation
import Testing
@testable import Outbound

/// Settings that changed their default reach everyone who never asked for the old one.
@MainActor
@Suite
struct PreferencesTests {
    @Test func theBorderStartsOffAndHoldingWhenHiddenOn() throws {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // As saved by versions that had the border on, and holding while hidden off, for everyone.
        defaults.set(true, forKey: "paperEdge")
        defaults.set(false, forKey: "pausesWhenHidden")
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.paperEdge)
        #expect(preferences.pausesWhenHidden)

        // Turned off, it stays off.
        preferences.pausesWhenHidden = false
        #expect(!Preferences(defaults: defaults).pausesWhenHidden)
        #expect(defaults.object(forKey: "pausesWhenHidden") == nil)

        // Asked for, it stays on.
        preferences.paperEdge = true
        #expect(Preferences(defaults: defaults).paperEdge)
        #expect(defaults.object(forKey: "paperEdge") == nil)
    }
}
