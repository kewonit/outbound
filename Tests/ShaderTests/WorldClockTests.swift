import CoreGraphics
import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// The world keeps to its own clock, which a render or a test may set, rather than the Mac's.
@MainActor
@Suite
struct WorldClockTests {
    /// Places laid out as the flight goes on take the season of the world's date, not the Mac's.
    @Test func newPlacesTakeTheSeasonOfTheWorldsDate() {
        let june = Date(timeIntervalSince1970: 1_781_870_400)
        let world = World(place: .first, time: 0, date: june, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.now = { june }
        world.journey.setSpeed(40, at: 0)
        world.journey.legLength = 2000
        for t in stride(from: 1.0, to: 600, by: 5) { world.advance(to: t) }
        let legs = world.journey.legs
        #expect(legs.count > 2)
        for leg in legs { #expect(leg.season.months == leg.place.season(on: june).months, "\(leg.place.id)") }
    }
}
