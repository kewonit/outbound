import CoreGraphics
import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// The slower flight still has room for everything that happens along the way.
@MainActor
@Suite
struct PaceTests {
    /// Only two places and one band can be on screen at once, so the join behind must be gone before the next comes into
    /// view, on the tallest display.
    @Test(arguments: Preferences.Pace.allCases)
    func everyStayLeavesAPlaceRoomToTurnIntoTheNext(pace: Preferences.Pace) {
        let room = 1440 * World.metresPerPoint + 2 * World.bankReach
        for stay in Preferences.Stay.allCases where stay != .forever {
            #expect(Double(stay.rawValue) * 60 * pace.speed >= room)
        }
    }

    /// However short the stay, a place lasts long enough for its band to leave the view before the next band comes
    /// into it, on a desktop taller than any one display, as a display turned on its side is.
    @Test(arguments: [982.0, 1692, 2560])
    func noPlaceIsTooShortForTheDesktop(height: Double) {
        let world = World(place: .first, time: 0, light: .alwaysDay)
        world.pointer = { nil }
        world.desktop = CGRect(x: 0, y: 0, width: 1440, height: height)
        world.home = world.desktop
        let speed = Preferences.Pace.slow.speed
        world.journey.setSpeed(speed, at: 0)
        world.journey.legLength = Double(Preferences.Stay.short.rawValue) * 60 * speed
        var starts = Set<Double>()
        for t in stride(from: 0.0, to: 4000, by: 5) {
            world.advance(to: t)
            world.journey.legs.forEach { starts.insert($0.start) }
        }
        let sorted = starts.sorted()
        #expect(sorted.count > 3)
        let room = height * World.metresPerPoint + 2 * World.bankReach + 20
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(b - a >= room - 1e-6) }
    }

    /// Each kind of flock keeps its own rate, so egrets come far more often than vultures.
    @Test func flocksKeepTheirOwnRates() {
        let area = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func flights(_ flock: Flock) -> Int {
            var count = 0
            var seen = false
            for t in stride(from: 0.0, to: 840 * 400, by: 30) {
                let now = flock.sighting(at: t, area: area, seed: 3) != nil
                if now && !seen { count += 1 }
                seen = now
            }
            return count
        }
        #expect(Double(flights(.egrets)) > 1.4 * Double(flights(.vultures)))
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
