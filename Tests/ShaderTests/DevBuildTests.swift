import Foundation
import Testing
@testable import Outbound

/// Only a build made with `scripts/build-app.sh dev` says which dev build it is.
@Suite
struct DevBuildTests {
    /// Release, debug and App Store builds all start from this Info.plist.
    private func trackedInfo() throws -> [String: Any] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Configuration/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func noOtherBuildHasTheLine() throws {
        let info = try trackedInfo()
        #expect(info["OutboundDevBuild"] == nil)
        #expect(AppDelegate.devBuildLine(info) == nil)
        #expect(AppDelegate.devBuildLine(nil) == nil)
        #expect(AppDelegate.devBuildLine(["OutboundDevBuild": ""]) == nil)
        // release.sh adds one to the build number, and the feedback page only takes a version made of numbers.
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        #expect(version.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil)
        #expect(build.wholeMatch(of: /[0-9]+/) != nil)
    }

    @Test func aDevBuildHasIt() throws {
        var info = try trackedInfo()
        info["OutboundDevBuild"] = "dev-1.6 · build 7.3 · 231875e"
        #expect(AppDelegate.devBuildLine(info) == "dev-1.6 · build 7.3 · 231875e")
    }
}
