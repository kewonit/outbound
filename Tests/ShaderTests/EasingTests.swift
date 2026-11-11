import Foundation
import Testing
@testable import Outbound
@testable import OutboundCore

/// The flight setting off again after a hold: gently, with no jump.
@MainActor
@Suite
struct EasingTests {
    @Test func settingOffGathersSpeedAndThenKeepsPace() {
        let length = 0.8
        #expect(Easing.rampLag(elapsed: 0, length: length) == 0)
        #expect(Easing.rampLag(elapsed: length, length: length) == length / 2)
        #expect(Easing.rampLag(elapsed: 10, length: length) == length / 2)
        // Flown time only ever grows, from a standstill to full pace.
        var flown = 0.0
        for step in 1...80 {
            let elapsed = Double(step) * 0.01
            let now = elapsed - Easing.rampLag(elapsed: elapsed, length: length)
            #expect(now >= flown)
            flown = now
        }
        #expect(abs((0.01 - Easing.rampLag(elapsed: 0.01, length: length)) / 0.01) < 0.01)
    }

    @Test func theFlightSetsOffWithoutAJump() {
        let world = World(place: .first, time: 0)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.advance(to: 10)
        world.hold(true, at: 10)
        world.hold(false, at: 20)
        // Carries on from where it stopped, still at first, then at full pace once it has gathered speed.
        #expect(world.renderTime(for: 20) == 10)
        #expect(world.renderTime(for: 20.01) - 10 < 0.001)
        let early = world.renderTime(for: 20.1) - world.renderTime(for: 20.09)
        let later = world.renderTime(for: 21.1) - world.renderTime(for: 21.09)
        #expect(early < later)
        #expect(abs(later - 0.01) < 1e-9)
        // Held again and let go: no jump either way.
        let before = world.renderTime(for: 20.4)
        world.advance(to: 20.4)
        world.hold(true, at: 20.4)
        #expect(abs(world.renderTime(for: 25) - before) < 1e-9)
        world.hold(false, at: 25)
        #expect(abs(world.renderTime(for: 25) - before) < 1e-9)
    }

    private func flying(to time: TimeInterval) -> World {
        let world = World(place: .first, time: 0)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.advance(to: time)
        return world
    }

    @Test func theFlightComesToRestWithoutAJump() {
        let world = flying(to: 10)
        let length = World.settleLength
        world.settle(at: 10)
        // At full pace as it begins.
        #expect(world.renderTime(for: 10) == 10)
        #expect(abs(world.renderTime(for: 10.001) - 10.001) < 1e-6)
        // Slowing all the way, never going back.
        var last = 10.0, pace = Double.infinity
        for step in 1...50 {
            let now = world.renderTime(for: 10 + Double(step) * length / 50)
            #expect(now >= last)
            #expect(now - last <= pace + 1e-12)
            pace = now - last
            last = now
        }
        // Then at rest, half the time on, however long it stays.
        #expect(abs(world.renderTime(for: 10 + length) - (10 + length / 2)) < 1e-9)
        #expect(world.renderTime(for: 99) == world.renderTime(for: 10 + length))
    }

    @Test func advancingFollowsTheFlightComingToRest() {
        let world = flying(to: 10)
        world.settle(at: 10)
        world.advance(to: 11)
        #expect(abs(world.time - (10 + World.settleLength / 2)) < 1e-9)
    }

    @Test func theFlightCarriesOnFromWhereItCameToRest() {
        let world = flying(to: 10)
        world.settle(at: 10)
        world.advance(to: 11)
        let rest = world.time
        world.hold(true, at: 11)
        #expect(world.renderTime(for: 50) == rest)
        world.hold(false, at: 50)
        #expect(abs(world.renderTime(for: 50) - rest) < 1e-9)
        #expect(world.renderTime(for: 50.5) > rest)
        // Then at full pace, behind only by what gathering speed cost.
        #expect(abs(world.renderTime(for: 60) - (rest + 10 - World.setOffLength / 2)) < 1e-9)
    }

    @Test func comingToRestWhileGatheringSpeedKeepsItsPlace() {
        let world = flying(to: 10)
        world.hold(true, at: 10)
        world.hold(false, at: 20)
        let from = world.renderTime(for: 20.3)
        world.settle(at: 20.3)
        #expect(abs(world.renderTime(for: 20.3) - from) < 1e-9)
        world.advance(to: 21)
        let rest = world.time
        world.hold(true, at: 21)
        world.hold(false, at: 30)
        #expect(abs(world.renderTime(for: 30) - rest) < 1e-9)
    }

    @Test func thinkingBetterOfItPartWayNeverGoesBack() {
        let world = flying(to: 10)
        world.settle(at: 10)
        world.advance(to: 10.2)
        let reached = world.renderTime(for: 10.2)
        // As when the dialog is cancelled while the flight is still slowing.
        world.hold(true, at: 10.2)
        world.hold(false, at: 10.2)
        #expect(abs(world.renderTime(for: 10.2) - reached) < 1e-9)
        #expect(world.renderTime(for: 10.6) > reached)
    }

    @Test func aHoldLetGoOfElsewhereLeavesTheFlightSlowing() {
        let world = flying(to: 10)
        world.settle(at: 10)
        // Any change to what holds the displays says so, with nothing holding the flight yet.
        world.hold(false, at: 10.1)
        #expect(abs(world.renderTime(for: 11) - (10 + World.settleLength / 2)) < 1e-9)
    }

    /// Frames are drawn a little ahead of the clock, so a hold part way through slowing carries on from the last one
    /// drawn, never from behind it.
    @Test func heldWhileSlowingItNeverGoesBackOnAFrameDrawnAhead() {
        let world = flying(to: 10)
        world.settle(at: 10)
        world.advance(to: 10.3)
        let drawn = world.time
        world.hold(true, at: 10.2)
        world.hold(false, at: 12)
        #expect(world.renderTime(for: 12) >= drawn - 1e-9)
        #expect(world.renderTime(for: 13) > drawn)
    }

    @Test func comingToRestWhileHeldChangesNothing() {
        let world = flying(to: 10)
        world.hold(true, at: 10)
        world.settle(at: 15)
        world.hold(false, at: 20)
        #expect(abs(world.renderTime(for: 20) - 10) < 1e-9)
        #expect(abs(world.renderTime(for: 30) - (20 - World.setOffLength / 2)) < 1e-9)
    }
}

/// The Mac asking whether to shut down, restart or log out, as loginwindow tells it.
@MainActor
@Suite
struct SessionEndWatchTests {
    private func watching() -> (SessionEndWatch, () -> [Bool]) {
        let watch = SessionEndWatch()
        var changes: [Bool] = []
        watch.onChange = { changes.append($0) }
        return (watch, { changes })
    }

    /// Waits up to five seconds for `count` changes, as other tests keeping the main thread busy can hold up the
    /// watch's timer well past its time.
    private func waitFor(_ count: Int, of changes: () -> [Bool]) async throws {
        let end = Date().addingTimeInterval(5)
        while changes().count < count, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aShutdownIsHeardOnce() {
        let (watch, changes) = watching()
        watch.heard("com.apple.shutdownInitiated")
        watch.heard("com.apple.logoutContinued")
        watch.heard("com.apple.pointOfNoReturn")
        #expect(changes() == [true])
        #expect(watch.ending)
    }

    @Test(arguments: ["com.apple.shutdownInitiated", "com.apple.restartInitiated", "com.apple.logoutInitiated"])
    func eachWayOfEndingIsHeard(name: String) {
        let (watch, changes) = watching()
        watch.heard(name)
        #expect(changes() == [true])
    }

    @Test func cancellingCarriesOn() {
        let (watch, changes) = watching()
        watch.heard("com.apple.shutdownInitiated")
        watch.heard("com.apple.logoutCancelled")
        #expect(changes() == [true, false])
        #expect(!watch.ending)
    }

    /// As on 31 October: confirmed, then an app refused to quit and it was cancelled 16 seconds later.
    @Test func cancellingAfterConfirmingCarriesOn() {
        let (watch, changes) = watching()
        watch.heard("com.apple.shutdownInitiated")
        watch.heard("com.apple.logoutContinued")
        watch.heard("com.apple.logoutCancelled")
        #expect(changes() == [true, false])
    }

    @Test func confirmedWithNothingAskedIsStillHeard() {
        let (watch, changes) = watching()
        watch.heard("com.apple.logoutContinued")
        #expect(changes() == [true])
    }

    @Test func aCancelWithNothingAskedChangesNothing() {
        let (watch, changes) = watching()
        watch.heard("com.apple.logoutCancelled")
        #expect(changes().isEmpty)
    }

    @Test func aWordThatNeverComesCantHoldTheFlight() async throws {
        let (watch, changes) = watching()
        watch.patience = 0.05
        watch.heard("com.apple.shutdownInitiated")
        try await waitFor(2, of: changes)
        #expect(changes() == [true, false])
    }

    /// Past the point of no return only the end itself should come, so it waits far longer, but should the session
    /// somehow carry on, the flight does too in the end, rather than staying still until Outbound opens again.
    @Test func pastThePointOfNoReturnItCarriesOnOnlyIfTheEndNeverComes() async throws {
        let (watch, changes) = watching()
        watch.patience = 0.05
        // Long enough that the first look comes before it, even with other tests keeping the main thread busy.
        watch.lastPatience = 2
        watch.heard("com.apple.shutdownInitiated")
        watch.heard("com.apple.pointOfNoReturn")
        try await Task.sleep(for: .milliseconds(250))
        #expect(changes() == [true])
        try await waitFor(2, of: changes)
        #expect(changes() == [true, false])
    }

    @Test func aPointOfNoReturnWithNothingAskedChangesNothing() async throws {
        let (watch, changes) = watching()
        watch.lastPatience = 0.05
        watch.heard("com.apple.pointOfNoReturn")
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes().isEmpty)
        #expect(!watch.ending)
    }

    @Test func pastThePointOfNoReturnItStays() async throws {
        let (watch, changes) = watching()
        watch.patience = 0.05
        watch.heard("com.apple.shutdownInitiated")
        watch.heard("com.apple.pointOfNoReturn")
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes() == [true])
    }
}
