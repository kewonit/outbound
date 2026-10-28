import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// Painting in pieces a slow GPU gets through quickly, and holding still in a way the menu can explain.
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
        // A while without trouble, and pieces grow back towards the usual time, never past it.
        cost.recover()
        #expect(cost.target == 2)
        for _ in 0..<10 { cost.recover() }
        #expect(cost.target == GroundCost.initial.target)
        // What can't be measured teaches nothing.
        let before = cost
        cost.finished(texels: 100, milliseconds: 1)
        cost.finished(texels: 1_000_000, milliseconds: .nan)
        cost.finished(texels: 1_000_000, milliseconds: 0)
        #expect(cost == before)
    }

    @Test func aDamagedCostStillCutsSensiblePieces() {
        for cost in [0, -1, Double.nan, .infinity, 1e-300] {
            #expect(GroundCost(millisecondsPerMillion: cost, target: 10).texelsPerPiece >= 16_384)
        }
        #expect(GroundCost(millisecondsPerMillion: 10, target: .infinity).texelsPerPiece >= 16_384)
        #expect(GroundCost(millisecondsPerMillion: 10, target: .nan).texelsPerPiece == 16_384)
    }

    @Test func oneStallCutsPiecesOnce() {
        var failures = GPUFailures()
        func failed(_ sent: Int, _ tooLong: Bool, _ time: Double) -> Bool {
            failures.failed(sent: sent, tooLong: tooLong, at: time)
        }
        // A stall takes down both displays' frames and two pieces: one cut.
        #expect(failed(0, true, 100))
        #expect(!failed(0, true, 100.01))
        #expect(!failed(0, false, 100.02))
        #expect(!failed(0, true, 104))
        #expect(failures.cuts == 1)
        // Right after it, what isn't a timeout is what the stall left behind, but work sent since that still runs too
        // long cuts again.
        for i in 0..<5 { #expect(!failed(1, false, 101 + Double(i) * 0.1)) }
        #expect(failed(1, true, 102))
        #expect(failures.cuts == 2)

        // Other failures cut on the third within a minute, counting only work sent since the last cut.
        #expect(!failed(2, false, 200))
        #expect(!failed(1, false, 201))
        #expect(!failed(2, false, 230))
        #expect(failed(2, false, 259))
        #expect(failures.cuts == 3)
        // Spread over more than a minute, they don't.
        #expect(!failed(3, false, 300))
        #expect(!failed(3, false, 340))
        #expect(!failed(3, false, 380))
        #expect(!failed(3, false, 420))
        #expect(failures.cuts == 3)
    }

    @Test func paintingThatCanWaitSlowsAndRecoversWithinBounds() {
        var budget = PaintBudget()
        #expect(budget.milliseconds == PaintBudget.usualMilliseconds)
        budget.backOff()
        #expect(budget.milliseconds == 2)
        for _ in 0..<10 { budget.backOff() }
        #expect(budget.milliseconds == 0.5)
        budget.recover()
        #expect(budget.milliseconds == 1)
        for _ in 0..<10 { budget.recover() }
        #expect(budget.milliseconds == PaintBudget.usualMilliseconds)
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

    @Test func theMenuAndThePowerTierAgreeOnHoldingStill() {
        for onBattery in [false, true] {
            for lowPower in [false, true] {
                for thermal in [PowerState.Thermal.nominal, .fair, .serious, .critical] {
                    for mode in PowerState.BatteryMode.allCases {
                        var state = PowerState()
                        state.onBattery = onBattery
                        state.lowPower = lowPower
                        state.thermal = thermal
                        state.batteryMode = mode
                        #expect(PowerTier.choose(state).frozen == (state.holdReason != nil))
                        let expected: PowerState.HoldReason? = lowPower ? .lowPower : thermal >= .serious ? .heat
                            : onBattery && mode == .still ? .battery : nil
                        #expect(state.holdReason == expected)
                    }
                }
            }
        }
    }

    @Test func flyingToAPlaceWhileHeldGetsThereAtOnce() {
        // Days into the clock, where a sweep begun just its length ago can round to not quite over.
        let world = World(place: .first, time: 314_138.2, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.advance(to: 314_168.2)
        world.hold(true, at: 314_168.2)
        let next = Place.all[1]
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: next, from: bottom, time: world.time, atOnce: true)
        #expect(!world.isSweeping)
        let middle = world.camera.y + Double(world.home.midY) * World.metresPerPoint
        #expect(world.journey.placeShown(at: middle, time: world.time).id == next.id)
        let top = world.camera.y + Double(world.desktop.maxY) * World.metresPerPoint
        let frame = world.frame(bottom: bottom + 50, top: top)
        #expect(frame.sweepFront == nil)
        #expect(frame.legB.place.id == next.id)
        // The old place ends below the view, at once rather than over a morph.
        #expect(frame.scene.morph.y < 0.01)
    }
}
