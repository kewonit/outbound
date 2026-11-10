import CoreGraphics
import Foundation
import OutboundCore
import Testing
import simd
@testable import Outbound

/// What dev builds use to bring things on without waiting: they never jump the flight, and they do what they say.
@MainActor
@Suite
struct DevHooksTests {
    private func world(_ place: Place = .first) -> World {
        let world = World(place: place, time: 0, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        return world
    }

    @Test func runningFastCarriesOnFromWhereItIs() {
        let world = world()
        let before = world.renderTime(for: 10)
        world.setTimeScale(5, at: 10)
        #expect(abs(world.renderTime(for: 10) - before) < 1e-9)
        #expect(abs(world.renderTime(for: 12) - (before + 10)) < 1e-9)
        world.setTimeScale(1, at: 12)
        #expect(abs(world.renderTime(for: 12) - (before + 10)) < 1e-9)
        #expect(abs(world.renderTime(for: 13) - (before + 11)) < 1e-9)
        #expect(world.timeScale == 1)
    }

    /// Held while running fast, the flight sets off again from just where it stopped.
    @Test func aHoldNeverJumpsTheFastFlight() {
        let world = world()
        world.setTimeScale(10, at: 0)
        world.advance(to: 2)
        let stopped = world.renderTime(for: 2)
        world.hold(true, at: 2)
        #expect(world.renderTime(for: 4) == world.time)
        world.hold(false, at: 5)
        #expect(abs(world.renderTime(for: 5) - stopped) < 1e-9)
        var last = stopped
        for d in stride(from: 5.1, to: 8, by: 0.1) {
            let t = world.renderTime(for: d)
            #expect(t > last)
            last = t
        }
        // Gathering speed over the usual 0.8 s, then ten seconds a second.
        #expect(abs((world.renderTime(for: 8) - world.renderTime(for: 7)) - 10) < 1e-6)
    }

    @Test func skippingMovesTheFlightOn() {
        let world = world()
        let before = world.renderTime(for: 10)
        world.skip(60)
        #expect(abs(world.renderTime(for: 10) - (before + 60)) < 1e-9)
    }

    @Test func changingTheCloudsSpeedNeverJumpsThem() {
        let world = world()
        world.advance(to: 300)
        let before = world.cloudSpace(SIMD2(100, 100), at: world.time)
        world.setCloudSpeed(3)
        let after = world.cloudSpace(SIMD2(100, 100), at: world.time)
        #expect(simd_length(after - before) < 1e-6)
        #expect(world.cloudSpeed == 3)
    }

    /// The next place comes on just beyond the top of the desktop, its band still out of view.
    @Test func movingOnBringsTheNextPlaceJustAboveTheView() throws {
        let world = world()
        world.journey.legLength = 1e6
        world.advance(to: 1)
        let first = world.journey.leg(at: world.camera.y).place.id
        #expect(world.journey.joins.isEmpty)
        #expect(world.moveOn())
        world.advance(to: 2)
        let join = try #require(world.journey.joins.first)
        let top = world.camera.y + Double(world.desktop.maxY) * World.metresPerPoint
        #expect(join > top + World.bankReach)
        #expect(join < top + 2 * World.bankReach + 60)
        #expect(world.journey.leg(at: join + 1).place.id != first)
        // And only one band ever shows at a time as it comes through.
        world.journey.setSpeed(30, at: world.time)
        for t in stride(from: 3.0, to: 120, by: 1) {
            world.advance(to: t)
            let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint
            let top = world.camera.y + Double(world.desktop.maxY) * World.metresPerPoint
            let showing = world.journey.joins.filter { $0 - World.bankReach < top && $0 + World.bankReach > bottom }
            #expect(showing.count <= 1)
        }
    }

    @Test func aFlockBroughtOnFliesAtOnce() throws {
        let world = world()
        world.advance(to: 50)
        world.bringFlock(.vultures)
        let (flock, sighting) = try #require(world.flock(at: world.time + 1))
        #expect(flock.formation == .circling)
        #expect(sighting.time > 0)
        #expect(world.flock(at: world.time + Flock.circlingLength + 5).map { $0.0.formation } != .circling)
    }

    /// Somewhere along the places with railways, skipping to the train has one passing the middle of the display.
    @Test func skippingToTheTrainBringsItThrough() {
        var found = false
        for place in Place.all where place.railway != nil {
            let world = world(place)
            world.journey.legLength = 4000
            world.advance(to: 1)
            guard let ahead = world.trainAhead() else { continue }
            world.skip(max(0, ahead - 10))
            for t in stride(from: 2.0, to: 40, by: 1) {
                world.advance(to: t)
                if world.trainPassing { found = true }
            }
            if found { break }
        }
        #expect(found)
    }

    @Test func clearingPutsTheWorldBack() {
        let world = world()
        world.setTimeScale(30)
        world.setCloudSpeed(2)
        world.bringFlock(.geese)
        world.clearDevOverrides()
        #expect(world.timeScale == 1)
        #expect(world.cloudSpeed == 1)
        #expect(world.forcedFlock == nil)
    }
}
