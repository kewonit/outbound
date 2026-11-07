import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// The band of cloud lying over the line where one place meets the next.
@MainActor
@Suite(.serialized)
struct BankTests {
    let bench = Bench.shared
    nonisolated static let columns: [Float] = [0, 900, 5123, 12000.5]

    /// The texture's rows run from the top down, a metre each.
    private func cover(_ bytes: [UInt8], x: Int, row: Int) -> Int { Int(bytes[(row * 256 + x) * 4]) }

    /// The two places must never be seen meeting: for 8 m either side of the join nothing shows but cloud.
    @Test(arguments: columns)
    func theJoinIsAlwaysUnderSolidCloud(x: Float) throws {
        for sideways in stride(from: Float(0), to: 4096, by: 256) {
            let bytes = try bench.renderBand(above: -128, x: x + sideways)
            for row in 120..<136 {
                for column in 0..<256 {
                    #expect(bytes[(row * 256 + column) * 4] == 255)
                }
            }
        }
    }

    /// Past its reach it leaves no trace, not even a shadow, so it can never pop into view.
    @Test(arguments: columns)
    func nothingShowsBeyondItsReach(x: Float) throws {
        let reach = Float(World.bankReach)
        for above in [reach, -reach - 256] {
            let bytes = try bench.renderBand(above: above, x: x)
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                #expect(bytes[pixel] == 0)
                #expect(bytes[pixel + 2] == 0)
            }
        }
    }

    /// It is only a thin band: open sky not far from the join on either side.
    @Test func itIsThin() throws {
        func mean(_ above: Float) throws -> Double {
            let bytes = try bench.renderBand(above: above)
            var sum = 0
            for pixel in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[pixel]) }
            return Double(sum) / Double(bytes.count / 4) / 255
        }
        let around = try mean(-128)
        #expect(around > 0.35 && around < 0.75)
        #expect(try mean(150) < 0.1)
        #expect(try mean(-406) < 0.1)
    }

    /// Each band has its own shape: the same field, a different part of it.
    @Test func noTwoBandsAreAlike() throws {
        let one = try bench.renderBand(above: -128, x: 900)
        let other = try bench.renderBand(above: -128, x: 900 + 1680 * 7.3)
        var different = 0
        for pixel in stride(from: 0, to: one.count, by: 4) where abs(Int(one[pixel]) - Int(other[pixel])) > 64 { different += 1 }
        #expect(different > 1000)
    }

    /// It belongs to the land: flown on, it is the very same picture further down the screen, so it can't fade or part.
    @Test(arguments: [Float(-250), -180, -60, 20])
    func itMovesWithTheLandAndNothingElse(above: Float) throws {
        let rows = 16
        let before = try bench.renderBand(above: above)
        let after = try bench.renderBand(above: above + Float(rows))
        var worst = 0, edge = 0
        for row in 0..<(256 - rows) {
            for x in 0..<256 {
                let was = cover(before, x: x, row: row)
                worst = max(worst, abs(cover(after, x: x, row: row + rows) - was))
                if was > 8 && was < 247 { edge += 1 }
            }
        }
        #expect(edge > 500)
        #expect(worst <= 1)
    }

    private func world() -> World {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let world = World(place: Place.named("serengeti")!, time: 0, date: Date(timeIntervalSince1970: 1_782_907_200), light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.home = frame
        world.desktop = frame
        world.journey.setSpeed(Preferences.Pace.slow.speed, at: 0)
        world.journey.legLength = Double(Preferences.Stay.short.rawValue) * 60 * Preferences.Pace.slow.speed
        return world
    }

    /// Flies on until a band is in view, and hands back its join.
    private func flyToBand(_ world: World) throws -> Double {
        var time = world.time
        while world.bank(from: world.camera.y, to: world.camera.y + 442) == nil, time < 4000 {
            time += 1
            world.advance(to: time)
        }
        return try #require(world.bank(from: world.camera.y, to: world.camera.y + 442))
    }

    /// However a stay is cut short, the next place is laid far enough ahead for its cloud to come in from out of view.
    @Test func cloudNeverAppearsInView() {
        let world = world()
        var time = 0.0
        var shown = false
        for step in 0..<4000 {
            time += 1
            if step == 500 { world.journey.legLength = 900 }
            let before = Set(world.journey.joins)
            world.advance(to: time)
            let top = world.camera.y + 442
            for join in Set(world.journey.joins).subtracting(before) { #expect(join - World.bankReach > top) }
            if world.bank(from: world.camera.y, to: top) != nil { shown = true }
        }
        #expect(shown)
    }

    /// A Fly To under way doesn't whip cloud away that is in view, and it drifts off with the land in the end.
    @Test func aFlyToLeavesABandInViewToDriftOff() throws {
        let world = world()
        let join = try flyToBand(world)
        let bottom = world.camera.y
        world.journey.fly(to: Place.named("lisse")!, from: bottom - 50, time: world.time)
        var time = world.time
        world.advance(to: time + 0.1)
        #expect(world.bank(from: bottom, to: bottom + 442) == join)
        while world.camera.y - World.bankReach < join, time < 8000 {
            time += 1
            world.advance(to: time)
        }
        #expect(world.bank(from: world.camera.y, to: world.camera.y + 442) != join)
    }

    /// Cloud still on its way goes with the place it led to: nothing crosses unbroken land.
    @Test func aFlyToForgetsABandNotYetInView() throws {
        let world = world()
        world.advance(to: 10)
        let bottom = world.camera.y
        #expect(world.bank(from: bottom, to: bottom + 442) == nil)
        let ahead = try #require(world.journey.joins.first)
        world.journey.fly(to: Place.named("lisse")!, from: bottom - 50, time: world.time)
        world.advance(to: 11)
        #expect(!world.journey.joins.contains(ahead))
        #expect(world.bank(from: ahead - 100, to: ahead + 100) != ahead)
    }

    /// The next place is laid clear of a band left in view, or one would pop out as the other came in.
    @Test func onlyOneBandShowsAfterAFlyTo() throws {
        let world = world()
        let join = try flyToBand(world)
        world.journey.fly(to: Place.named("lisse")!, from: world.camera.y - 50, time: world.time)
        world.advance(to: world.time + 1)
        let next = try #require(world.journey.joins.first)
        #expect(next - join >= 442 + 2 * World.bankReach)
    }

    /// A painting taken with a band left in view opens with it there.
    @Test func aMomentKeepsABandLeftInView() throws {
        let world = world()
        let join = try flyToBand(world)
        world.journey.fly(to: Place.named("lisse")!, from: world.camera.y - 50, time: world.time)
        world.advance(to: world.time + 0.1)
        let moment = world.moment()
        #expect(moment.band == join)
        let data = try JSONEncoder().encode(moment)
        let reopened = try #require(World(resuming: try JSONDecoder().decode(World.Moment.self, from: data), at: moment.time + 1, light: .alwaysDay))
        let bottom = reopened.camera.y
        #expect(reopened.bank(from: bottom, to: bottom + 442) == join)
    }
}
