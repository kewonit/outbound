import Foundation
import Metal
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

    /// The most a handover's traffic changes in one step, where it can't be put down to moving along. A car or boat
    /// going on its way barely changes how much of it can be seen on a stretch of about 96 m, unless it is crossing the
    /// end of the stretch, and then it is halfway along the next one, which overlaps. So a jump in two overlapping
    /// stretches at once is something appearing or vanishing.
    func worstStep(_ probe: String, out id: String, seconds: Double, step: Double, columns: Int, rows: Int,
                   in library: MTLLibrary) throws -> Float {
        var last: [Float]?
        var worst: Float = 0
        for moment in stride(from: 0, to: seconds, by: step) {
            let scene = try bench.handover(id, after: moment)
            let seen = try bench.probe(probe, scene: scene, in: library)
            let count = seen.count / columns
            var perRow = [Float](repeating: 0, count: count)
            for (i, c) in seen.enumerated() { perRow[i / columns] += abs(c.x - 0.45) + abs(c.y - 0.5) + abs(c.z - 0.35) }
            let stretches = stride(from: 0, to: count - rows + 1, by: rows / 2).map { perRow[$0..<$0 + rows].reduce(0, +) }
            if let last {
                let jumps = zip(stretches, last).map { abs($0 - $1) }
                worst = max(worst, zip(jumps, jumps.dropFirst()).map { min($0, $1) }.max() ?? 0)
            }
            last = stretches
        }
        return worst
    }

    /// Measured when this was written: at worst about 2.3 for cars and 1.6 for boats, and for the shaders before the
    /// fades 6.4 and 10.3, a car or a boat with its wake coming or going in one step.
    @Test(arguments: Place.all.map(\.id))
    func carsAndBoatsNeverAppearOrVanishInOneStep(_ id: String) throws {
        let cars = try worstStep("probeCars", out: id, seconds: 64, step: 1.0 / 15, columns: 8, rows: 64, in: bench.current)
        let boats = try worstStep("probeBoats", out: id, seconds: 220, step: 0.2, columns: 16, rows: 32, in: bench.current)
        #expect(cars < 3, "a car out of \(id)")
        #expect(boats < 3, "a boat out of \(id)")
    }

    /// Ground is painted a row at a time as it comes into view, so what stands on a patch line has to come out the same
    /// whenever it is painted, and the scene is measured from a reference that steps on as the flight goes.
    @Test(arguments: Place.all.map(\.id))
    func aHandoverPaintsTheSameAfterTheReferenceStepsOn(_ id: String) throws {
        let scene = try #require(try bench.handovers().first { $0.place == id })
        var later = scene
        later.gpu = try bench.handover(id, after: 2048 / 4.2)
        let step = scene.gpu.morph.x - later.gpu.morph.x
        #expect(step == 2048)
        let now = try bench.renderGround(scene, from: Self.start(scene), width: Self.width, height: Self.height,
                                         in: bench.current)
        let then = try bench.renderGround(later, from: Self.start(scene) - step, width: Self.width, height: Self.height,
                                          in: bench.current)
        let changed = Self.changed(now.color, then.color, rows: Array(0..<Self.height), bytes: 4)
        #expect(changed <= 32, "\(changed) pixels out of \(id) moved")
    }

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
