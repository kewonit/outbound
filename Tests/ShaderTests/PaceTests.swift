import CoreGraphics
import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// The slower flight still has room for everything that happens along the way.
@MainActor
@Suite
struct PaceTests {
    /// Only two places can be on screen at once, so the join behind must be gone before the next comes into view, on the
    /// tallest display and with the margin the frame keeps below it.
    @Test(arguments: Preferences.Pace.allCases)
    func everyStayLeavesAPlaceRoomToTurnIntoTheNext(pace: Preferences.Pace) {
        let room = 1440 * World.metresPerPoint + 200
        for stay in Preferences.Stay.allCases where stay != .forever {
            #expect(Double(stay.rawValue) * 60 * pace.speed >= room)
        }
    }

    /// The slowest birds over two wide displays, which must never vanish while they can still be seen.
    @Test func aFlightLeavesTheScreenBeforeItsTimeIsUp() {
        let area = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        var last: SIMD2<Double>?
        for t in stride(from: 0.0, to: 40000, by: 1) {
            let seen = Flock.egrets.sighting(at: t, area: area, seed: 1)
            if seen == nil, let last { #expect(!area.contains(CGPoint(x: last.x, y: last.y))) }
            last = seen?.position
        }
    }
}

/// What is painted along the way must not depend on where the reference happens to have stepped to.
@MainActor
@Suite
struct ReferenceTests {
    /// The count that says which crossroad is which grows with the reference, a spacing at a time, from the origin.
    @Test func crossroadsAreCountedFromTheOrigin() {
        let world = World(place: .first, time: 0)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        for seconds in [0.0, 400, 800, 1600] {
            world.advance(to: seconds)
            let frame = world.frame(bottom: 0, top: 1)
            let expected = (frame.reference / World.crossroadSpacing).rounded(.down)
            #expect(Double(frame.scene.bends.w) == expected)
            #expect(abs(Double(frame.scene.road.w) - frame.reference.truncatingRemainder(dividingBy: World.crossroadSpacing)) < 1e-3)
        }
    }
}
