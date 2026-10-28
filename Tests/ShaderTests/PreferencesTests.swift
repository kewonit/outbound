import Foundation
import Testing
@testable import Outbound

/// Settings that start off stay off for everyone who never asked for them.
@MainActor
@Suite
struct PreferencesTests {
    @Test func theBorderAndPausingWhenHiddenStartOff() throws {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // As saved by a version that had the border on for everyone.
        defaults.set(true, forKey: "paperEdge")
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.paperEdge)
        #expect(!preferences.pausesWhenHidden)

        // Asked for, it stays on.
        preferences.paperEdge = true
        #expect(Preferences(defaults: defaults).paperEdge)
        #expect(defaults.object(forKey: "paperEdge") == nil)
    }
}
