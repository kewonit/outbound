import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// Everything on the land gives way to what came before it, so nothing stands on anything else.
@MainActor
@Suite(.serialized)
struct OverlapTests {
    let bench = Bench.shared

    /// A scene over the place itself. The ones `Bench.scenes` makes fly on until a train comes by, by when many are over
    /// the next place or the one after, so a rule held there says nothing about the place in their name.
    private func scene(over id: String) throws -> SceneGPU {
        let place = try #require(Place.named(id))
        let noon = Date(timeIntervalSince1970: 1_782_907_200)
        let world = World(place: place, time: 0, date: noon, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.now = { noon }
        world.journey.followsCalendar = false
        world.journey.refreshSeasons(date: noon)
        world.advance(to: 1)
        return world.frame(bottom: 0, top: 442).scene
    }

    private func collisions(_ kernel: String, out id: String) throws -> [Int] {
        let seen = try bench.probe(kernel, scene: try scene(over: id))
        return [\SIMD4<Float>.x, \.y, \.z, \.w].map { part in seen.filter { $0[keyPath: part] > 0 }.count }
    }

    /// Houses a place builds per kilometre of road, over the 30 km the probe walks.
    private func housesPerKm(_ id: String) throws -> Double {
        Double(try bench.probe("countHomes", scene: try scene(over: id)).filter { $0.x > 0 }.count) / 30.72
    }

    /// How built up a place is comes from the place: its `villages` has to make a real difference, or the empty places
    /// fill up with suburbs.
    @Test func eachPlaceBuildsAboutAsManyHousesAsItShould() throws {
        let perKm: [String: ClosedRange<Double>] = [
            "punjab": 15...25, "niigata": 11...19, "lisse": 12...21, "normandy": 10...18,
            "lapland": 2...9, "pampa": 1...7, "serengeti": 0...0, "kansas": 0...0,
        ]
        for place in Place.all {
            let houses = try housesPerKm(place.id)
            #expect(try #require(perKm[place.id]).contains(houses), "\(place.id): \(houses) houses per km")
        }
    }

    @Test(arguments: Place.all.map(\.id))
    func nothingStandsOnAnythingElse(_ id: String) throws {
        let homes = try collisions("auditHomes", out: id)
        let trees = try collisions("auditTrees", out: id)
        let landmarks = try collisions("auditLandmarks", out: id)
        let rivals = try collisions("auditRivals", out: id)
        let paths = try collisions("auditPaths", out: id)
        let junctions = try collisions("auditJunctions", out: id)
        #expect((homes + trees + landmarks + rivals + paths + junctions).allSatisfy { $0 == 0 },
                "\(id): homes on crossroad, rail, pond, landmark \(homes); trees on crossroad, rail, pond, road \(trees); ponds on road, rail, landmarks on crossroad, rail \(landmarks); paths on a house, short of the road \(paths); junctions on water \(junctions)")
    }
}
