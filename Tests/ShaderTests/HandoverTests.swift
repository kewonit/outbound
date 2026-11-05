import Foundation
import Testing
@testable import Outbound
@testable import OutboundCore

/// One place turning into the next as the flight goes on.
///
/// The scenes ShaderTests holds against Shipped/ have no handover in them, so these fly to one out of every place.
@MainActor
@Suite(.serialized)
struct HandoverTests {
    let bench = Bench.shared
    /// A strip of ground up the river, wide enough for the road and both banks, from just below the handover to
    /// just above it.
    static let width = 512
    static let margin: Float = 32
    static let height = Int((Float(Journey.morphLength) + 2 * margin) / Float(World.metresPerPoint))

    static func start(_ scene: Bench.Scene) -> Float { scene.gpu.morph.x - margin }

    /// Rows of the strip, counted from the bottom, where the land isn't turning.
    static func settledRows(_ scene: Bench.Scene) -> [Int] {
        let texel = Float(World.metresPerPoint)
        return (0..<height).filter { row in
            let y = start(scene) + (Float(row) + 0.5) * texel
            return y < scene.gpu.morph.x || y > scene.gpu.morph.x + scene.gpu.morph.y
        }
    }

    /// How many pixels in the given rows of two images of `bytes` a pixel are more than a level apart.
    static func changed(_ a: [UInt8], _ b: [UInt8], rows: [Int], bytes: Int) -> Int {
        var changed = 0
        for row in rows {
            for pixel in row * width..<(row + 1) * width {
                let range = pixel * bytes..<(pixel + 1) * bytes
                if range.contains(where: { abs(Int(a[$0]) - Int(b[$0])) > 1 }) { changed += 1 }
            }
        }
        return changed
    }

    /// Stray pixels two builds of the same shader may differ by: the compiler rounds a little differently now and
    /// then, which can tip a pixel sitting right on a hash's threshold.
    static let stray = 4

    @Test func theScenesHeldAgainstShippedHoldNoHandover() throws {
        for scene in try bench.scenes() where scene.gpu.morph.x > -1e8 {
            let top = scene.bottom + 256 * Float(World.metresPerPoint)
            let turning = scene.gpu.morph.x < top && scene.gpu.morph.x + scene.gpu.morph.y > scene.bottom
            #expect(!turning, "\(scene.place) has a handover in it, so Shipped/ now speaks for part of one")
        }
    }

    @Test func everyPlaceTurnsIntoTheNext() throws {
        let scenes = try bench.handovers()
        #expect(scenes.count == Place.all.count)
        for scene in scenes {
            let middle = scene.gpu.morph.x + scene.gpu.morph.y / 2
            #expect(scene.gpu.morph.z < 0, "\(scene.place) is flying, not sweeping")
            #expect(abs(scene.gpu.morph.y - Float(Journey.morphLength)) < 1, "\(scene.place)")
            #expect(middle > scene.bottom && middle < scene.bottom + 442, "\(scene.place) is in view")
        }
    }

    @Test(arguments: Place.all.map(\.id))
    func theLandEitherSideOfAHandoverIsUntouched(_ id: String) throws {
        let scene = try #require(try bench.handovers().first { $0.place == id })
        let now = try bench.renderGround(scene, from: Self.start(scene), width: Self.width, height: Self.height,
                                         in: bench.current)
        let then = try bench.renderGround(scene, from: Self.start(scene), width: Self.width, height: Self.height,
                                          in: bench.shipped)
        let rows = Self.settledRows(scene)
        #expect(rows.count > 100)
        #expect(Self.changed(now.color, then.color, rows: rows, bytes: 4) <= Self.stray, "ground colour out of \(id)")
        #expect(Self.changed(now.night, then.night, rows: rows, bytes: 2) <= Self.stray, "night light out of \(id)")
    }
}
