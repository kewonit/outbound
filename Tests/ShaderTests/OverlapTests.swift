import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// Everything on the land gives way to what came before it, so nothing stands on anything else.
@MainActor
@Suite(.serialized)
struct OverlapTests {
    let bench = Bench.shared

    private func collisions(_ kernel: String, out id: String) throws -> [Int] {
        let scene = try #require(try bench.scenes().first { $0.place == id })
        let seen = try bench.probe(kernel, scene: scene.gpu)
        return [\SIMD4<Float>.x, \.y, \.z, \.w].map { part in seen.filter { $0[keyPath: part] > 0 }.count }
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
