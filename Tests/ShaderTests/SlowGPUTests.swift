import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// Painting in pieces a slow GPU gets through quickly.
@MainActor
@Suite
struct SlowGPUTests {
    @Test func piecesStartSmallAndChangeAtMostTwofoldAPiece() {
        var cost = GroundCost.initial
        let first = cost.texelsPerPiece
        #expect(first == Int(10 / 150.0 * 1e6))
        // A fast GPU: each piece at most doubles.
        cost.finished(texels: first, milliseconds: 0.5)
        #expect(cost.texelsPerPiece <= first * 2 + 1)
        for _ in 0..<20 { cost.finished(texels: cost.texelsPerPiece, milliseconds: Double(cost.texelsPerPiece) / 1e6 * 9) }
        #expect(abs(cost.millisecondsPerMillion - 9) < 0.01)
        // Slower than thought: each piece half the last, until they fit.
        cost.finished(texels: 1_000_000, milliseconds: 300)
        #expect(cost.millisecondsPerMillion == 18)
        for _ in 0..<10 { cost.finished(texels: cost.texelsPerPiece, milliseconds: Double(cost.texelsPerPiece) / 1e6 * 300) }
        #expect(cost.millisecondsPerMillion == 300)
        #expect(cost.texelsPerPiece == Int(10 / 300.0 * 1e6))
        // Work stopped for running too long: a quarter of the time from then on, but never pieces of nothing.
        cost.backOff()
        #expect(cost.target == 2.5)
        for _ in 0..<10 { cost.backOff() }
        #expect(cost.target == 1)
        for _ in 0..<10 { cost.finished(texels: 1_000_000, milliseconds: 50_000) }
        #expect(cost.texelsPerPiece == 16_384)
        // What can't be measured teaches nothing.
        let before = cost
        cost.finished(texels: 100, milliseconds: 1)
        cost.finished(texels: 1_000_000, milliseconds: .nan)
        cost.finished(texels: 1_000_000, milliseconds: 0)
        #expect(cost == before)
    }

    @Test func piecesCoverEveryTexelOnceWithTheirOwnOrigins() {
        var random = SplitMix(seed: 7)
        func next(_ upTo: Int) -> Int { Int(random.next() * Double(upTo)) }
        for round in 0..<40 {
            // Draws for both caches, as a frame during a Fly To has them.
            var strokes: [GroundStrokes.Stroke] = []
            for i in 0..<(1 + next(6)) {
                let scissor = MTLScissorRect(x: next(100), y: next(100), width: 1 + next(90), height: 1 + next(70))
                let params = GroundGPU(origin: SIMD4(Float(i), Float(round), 0, 0), texel: .zero)
                strokes.append(.init(params: params, scissor: scissor, into: i < 3 ? 0 : 1))
            }
            let size = 1 + next(3000)
            var queue = GroundStrokes(strokes)
            #expect(queue.texels == strokes.reduce(0) { $0 + $1.texels })
            var painted: [Int: [Int: Int]] = [:]
            var pieces = 0
            while !queue.isEmpty {
                let piece = queue.take(texels: size)
                pieces += 1
                #expect(!piece.isEmpty)
                #expect(Set(piece.map(\.into)).count == 1)
                let widest = piece.map(\.scissor.width).max() ?? 0
                #expect(piece.reduce(0) { $0 + $1.texels } <= max(size, widest))
                for band in piece {
                    let own = Int(band.params.origin.x)
                    // Cut only into bands of whole rows of its own draw, which keep its origin.
                    #expect(band.params.origin == strokes[own].params.origin)
                    #expect(band.scissor.x == strokes[own].scissor.x && band.scissor.width == strokes[own].scissor.width)
                    for row in band.scissor.y..<(band.scissor.y + band.scissor.height) {
                        painted[own, default: [:]][row, default: 0] += 1
                    }
                }
                guard pieces < 100_000 else { break }
            }
            for (i, stroke) in strokes.enumerated() {
                let rows = painted[i] ?? [:]
                #expect(rows.count == stroke.scissor.height)
                #expect(rows.values.allSatisfy { $0 == 1 })
                #expect(rows.keys.min() == stroke.scissor.y)
            }
        }
    }

}
