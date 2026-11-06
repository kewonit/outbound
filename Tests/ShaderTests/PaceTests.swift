import CoreGraphics
import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// The slower flight still has room for everything that happens along the way.
@MainActor
@Suite
struct PaceTests {
    /// Only two places can be on screen at once, so one must finish turning into the next before a third comes into
    /// view, on the tallest display and with the margin the frame keeps below it.
    @Test(arguments: Preferences.Pace.allCases)
    func everyStayLeavesAPlaceRoomToTurnIntoTheNext(pace: Preferences.Pace) {
        let room = Journey.morphLength + 1440 * World.metresPerPoint + 200
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
