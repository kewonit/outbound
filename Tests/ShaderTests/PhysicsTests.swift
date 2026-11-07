import CoreGraphics
import Foundation
import Testing
@testable import Outbound
@testable import OutboundCore

/// The world keeps to one sun, one wind and one sky.
@MainActor
@Suite
struct PhysicsTests {
    /// Every shadow is height times one length, which the tallest trees can still throw.
    @Test func oneShadowLengthForEverything() {
        for degrees in stride(from: 1.0, to: 90, by: 1) {
            let length = Sun(elevation: degrees * .pi / 180, azimuth: 0).shadowLength
            #expect(length <= 1.5 && length >= 0.35)
        }
        #expect(abs(Sun.fair.shadowLength - 1 / tan(0.85)) < 1e-9)
    }

    /// A place at its best is lit by the sun of that season.
    @Test func aSeasonHasItsOwnSun() throws {
        let biome = Place.first.signatureSeason.biome
        func season(_ months: Set<Int>) -> Season { Season(months: months, line: "", biome: biome) }
        #expect(abs(season([6, 7, 8]).middleDay - 196) < 6)
        #expect(abs(season([12, 1, 2]).middleDay - 15) < 6 || season([12, 1, 2]).middleDay > 360)
        #expect(abs(season([3]).middleDay - 74) < 6)
    }

    /// Turning the seasons on or off moves the sun with them at once, so the land is painted again once, not a second
    /// time when the sun catches up.
    @Test(arguments: [false, true])
    func theSunFollowsTheSeasonsAtOnce(calendar: Bool) throws {
        let world = World(place: try #require(Place.named("lapland")), time: 1000, light: .yourTime)
        world.journey.followsCalendar = calendar
        world.journey.refreshSeasons()
        world.seasonsChanged()
        let revision = world.revision
        world.advance(to: 1030)
        #expect(world.revision == revision)
    }

    /// A train is drawn only over its own place's land: everywhere in a view of that place alone, on its side of a
    /// join, and nowhere in a view of other places.
    @Test func aTrainIsOnlyDrawnOverItsOwnPlace() {
        let place = Place.first
        let legs = (0..<3).map {
            Leg(index: $0, place: place, season: place.signatureSeason, start: Double($0) * 2000, sweepStart: nil)
        }
        #expect(World.trainSide(of: legs[0], nil, nil) == 0)
        #expect(World.trainSide(of: legs[0], legs[0], legs[0]) == 0)
        #expect(World.trainSide(of: legs[0], legs[0], legs[1]) == 1)
        #expect(World.trainSide(of: legs[1], legs[0], legs[1]) == 2)
        #expect(World.trainSide(of: legs[0], legs[1], legs[2]) == 3)
        #expect(World.trainSide(of: legs[0], legs[1], legs[1]) == 3)
    }

    /// Birds fly below the clouds they are drawn under.
    @Test func flocksFlyUnderTheClouds() {
        for flock in [Flock.geese, .swans, .cranes, .flamingos, .egrets, .rooks, .vultures] {
            #expect(flock.altitude < World.cloudHeight)
        }
    }

    /// Clouds are carried by the wind faster than the gusts at the ground, and the same way.
    @Test func cloudsRideTheSameWindFasterThanTheGusts() {
        let clouds = World.cloudWind, gusts = World.gustWind
        #expect((clouds.x * clouds.x + clouds.y * clouds.y) > 2.25 * (gusts.x * gusts.x + gusts.y * gusts.y))
        #expect(abs(atan2(clouds.y, clouds.x) - atan2(gusts.y, gusts.x)) < 1e-9)
    }

    /// Cars gain on their slots and fall back, but never so far that one could reach the next, and an hour on, when
    /// the clock they run on wraps, each is just where it was.
    @Test func carsNeverReachEachOther() throws {
        let scene = try #require(try Bench.shared.scenes().first)
        let drift = try Bench.shared.probe("auditCarDrift", scene: scene.gpu)
        let longest: Float = 9.2
        #expect(drift.allSatisfy { abs($0.x) <= 30.01 })
        #expect(Float(World.carSlot) - 2 * 30 - longest > 50)
        #expect(drift.allSatisfy { abs($0.y) < 0.05 })
        #expect(Set(drift.map { ($0.x * 10).rounded() }).count > 100)
    }

    /// Boats make headway against the current, and go down faster than up.
    @Test func boatsMoveThroughTheWater() {
        #expect(World.boatSpeed - World.current > 1)
        #expect(World.current > 0.2 && World.current < World.boatSpeed / 3)
    }

    /// However fast the flight, a flock is never there one frame and gone the next while it can be seen: it flies off,
    /// or climbs out of sight.
    @Test(arguments: Preferences.Pace.allCases)
    func flocksNeverVanishInView(pace: Preferences.Pace) {
        for place in Place.all {
            let world = World(place: place, time: 0, light: .alwaysDay)
            world.pointer = { nil }
            world.isDesktop = { _ in false }
            world.journey.setSpeed(pace.speed, at: 0)
            world.journey.staysPut = true
            let area = world.desktop
            var last: (Flock, FlockSighting)?
            for second in stride(from: 0.0, to: 9000, by: 0.5) {
                let now = world.flock(at: second)
                if now == nil, let (flock, seen) = last {
                    let visible = flock.formation == .circling ? Flock.circlingVisibility(seen.time) : 1
                    let inside = area.insetBy(dx: -60, dy: -60).contains(CGPoint(x: seen.position.x, y: seen.position.y))
                    #expect(!inside || visible < 0.02, "\(place.id) at \(second)")
                }
                last = now
            }
        }
    }
}
