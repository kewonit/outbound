import Foundation
import Testing
@testable import Outbound
@testable import OutboundCore

/// Opening again over the painting the last run left on the desktop, as after a restart.
@MainActor
@Suite
struct CarryOnTests {
    /// A world some way into its journey, over a later leg than its first.
    private func flown() -> World {
        let world = World(place: .first, time: 40, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        for step in 1...(4 * 2000) { world.advance(to: 40 + Double(step) * 0.25) }
        return world
    }

    @Test func theViewOpensOnThePaintingsMomentAndSetsOffFromThere() throws {
        let world = flown()
        let moment = world.moment()
        let saved = try JSONDecoder().decode(World.Moment.self, from: JSONEncoder().encode(moment))
        // The clock starts again from nearly nothing after a restart.
        let resumed = try #require(World(resuming: saved, at: 3, light: .alwaysDay))
        #expect(resumed.renderTime(for: 3) == moment.time)
        #expect(resumed.birdPose(at: moment.time) == world.birdPose(at: moment.time))
        #expect(world.journey.leg(at: world.camera.y).index > 0)

        // Every display's view of that moment is just what it was, where starting the place afresh shows other land.
        let afresh = World(place: world.journey.leg(at: world.camera.y).place, time: moment.time, light: .alwaysDay)
        func sameView(_ a: World, _ b: World, _ frame: CGRect) -> Bool {
            let bottom = a.camera.y + Double(frame.minY) * World.metresPerPoint
            let top = a.camera.y + Double(frame.maxY) * World.metresPerPoint
            var one = a.frame(bottom: bottom, top: top, at: moment.time).scene
            var other = b.frame(bottom: bottom, top: top, at: moment.time).scene
            return withUnsafeBytes(of: &one) { x in withUnsafeBytes(of: &other) { y in x.elementsEqual(y) } }
                && a.camera(at: moment.time) == b.camera(at: moment.time)
        }
        for frame in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 2560, height: 1440)] {
            #expect(sameView(world, resumed, frame))
            #expect(!sameView(world, afresh, frame))
        }

        // Over the same legs, setting off gently, then at the usual pace.
        #expect(resumed.journey.snapshot == moment.journey)
        #expect(resumed.renderTime(for: 3.05) - moment.time < 0.001)
        let pace = resumed.renderTime(for: 13) - resumed.renderTime(for: 12)
        #expect(abs(pace - 1) < 1e-9)
    }

    @Test func aMomentOverAPlaceThatHasGoneOpensAfresh() {
        var moment = flown().journey.snapshot
        moment.legs[0].place = "atlantis"
        #expect(Journey(moment) == nil)
    }
}
