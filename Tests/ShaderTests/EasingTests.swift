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
}
