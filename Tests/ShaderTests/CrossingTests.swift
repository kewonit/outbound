import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// One place giving way to the next under cloud, as the GPU paints it and as a whole world flies it.
@MainActor
@Suite(.serialized)
struct CrossingTests {
    let bench = Bench.shared

    /// Laptop, tall display, and two displays stacked, in metres.
    nonisolated static let heights: [Float] = [442, 648, 1100]
    static let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(900, 16000), SIMD2(5123, 777), SIMD2(12000.5, 9000.25)]

    /// Nothing of the land may show while it changes: every pixel is wholly cloud, and wholly the bank.
    @Test(arguments: heights)
    func theBankHidesEverythingWhileClosed(height: Float) throws {
        for corner in Self.corners {
            for flow in stride(from: Float(150), to: 200, by: 7) {
                let bytes = try bench.renderCrossing(closure: 1, clearing: 0, flow: flow, height: height, at: corner)
                var thinnest: UInt8 = 255, mostPlain: UInt8 = 0
                for pixel in stride(from: 0, to: bytes.count, by: 4) {
                    thinnest = min(thinnest, bytes[pixel])
                    mostPlain = max(mostPlain, bytes[pixel + 3])
                }
                #expect(thinnest == 255)
                #expect(mostPlain == 0)
            }
        }
    }

    /// Before the first wisp and after the last, the sky is just as it is on any other day.
    @Test(arguments: heights)
    func aCrossingLeavesNothingBehind(height: Float) throws {
        for corner in Self.corners {
            let plain = try bench.renderCrossing(closure: 0, clearing: 0, flow: 0, height: height, at: corner)
            for (closure, clearing) in [(Float(0.0005), Float(0)), (1, 0.9995), (1, 1)] {
                let bytes = try bench.renderCrossing(closure: closure, clearing: clearing, flow: 300, height: height, at: corner)
                var worst = 0
                for i in bytes.indices { worst = max(worst, abs(Int(bytes[i]) - Int(plain[i]))) }
                #expect(worst <= 2, "closure \(closure), clearing \(clearing)")
            }
        }
    }

    /// Nothing flashes: stepped frame by frame, the amount of cloud on screen only ever moves gently.
    @Test func theCloudComesAndGoesGently() throws {
        let crossing = Crossing(start: 0)
        var last: Double?
        var worst = 0.0
        var heaviest = 0.0
        for t in stride(from: -0.5, to: crossing.end + 0.5, by: 1.0 / 30) {
            let bytes = try bench.renderCrossing(closure: Float(crossing.closure(at: t)), clearing: Float(crossing.clearing(at: t)),
                                                 flow: Float(max(t, 0) * World.deckSpeed), height: 442, at: SIMD2(900, 400))
            var sum = 0
            for pixel in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[pixel]) }
            let cover = Double(sum) / Double(bytes.count / 4) / 255
            if let last { worst = max(worst, abs(cover - last)) }
            last = cover
            heaviest = max(heaviest, cover)
        }
        #expect(heaviest == 1)
        // Under one part in 200 of the screen a frame, so even the fastest of it takes seconds to cross.
        #expect(worst < 0.005)
    }

    private func world(light: World.Light = .alwaysDay, place: Place = Place.named("serengeti")!) -> World {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let world = World(place: place, time: 0, date: Date(timeIntervalSince1970: 1_782_907_200), light: light)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.now = { Date(timeIntervalSince1970: 1_782_907_200) }
        world.home = frame
        world.desktop = frame
        world.centreRiver(on: frame)
        world.journey.setSpeed(Preferences.Pace.slow.speed, at: 0)
        world.journey.legLength = Double(Preferences.Stay.short.rawValue) * 60 * Preferences.Pace.slow.speed
        return world
    }

    /// Flies on to the first sight of a crossing, as the app would, and hands it back.
    private func flyToCrossing(_ world: World) throws -> Crossing {
        var time = 0.0
        while !world.crossingUnderWay, time < 4000 {
            time += 1
            world.advance(to: time)
        }
        return try #require(world.journey.crossing)
    }

    /// Paintings of the desktop wait for it, and the place after it has the view to itself. Herds go by the legs in the
    /// frame, so an old leg kept on would graze the old place's animals on the new land.
    @Test func aWorldComesOutOfACrossingOverTheNextPlaceAlone() throws {
        let world = world()
        let crossing = try flyToCrossing(world)
        let before = world.journey.legs.last!.index
        var t = world.time
        while t < crossing.end + 1 {
            t += 0.1
            world.advance(to: t)
            if t < crossing.end - 0.2 { #expect(world.isSweeping) }
        }
        #expect(!world.isSweeping)
        #expect(world.crossingCloud(at: world.time) == nil)
        #expect(world.journey.legs.last!.index == before + 1)
        let bottom = world.camera.y
        let frame = world.frame(bottom: bottom, top: bottom + 442)
        #expect(frame.legB.place.id == Place.named("normandy")!.id)
        #expect(frame.legA.index == frame.legB.index)
    }

    /// Places keep their own hours: however far apart, the sky's light never jumps, though the sun itself does.
    @Test func placeTimeGlidesUnderTheCloud() throws {
        let world = world(light: .placeTime, place: Place.named("lapland")!)
        let crossing = try flyToCrossing(world)
        var t = world.time
        var last = world.skyLight(at: t)
        var lastSun = world.sun
        var jumped = false
        while t < crossing.opens + 2 {
            t += 1.0 / 30
            world.advance(to: t)
            let now = world.skyLight(at: t)
            #expect(abs(now.night - last.night) < 0.02)
            let step = now.light - last.light
            #expect(max(abs(step.x), abs(step.y), abs(step.z), abs(step.w)) < 0.02)
            if world.sun != lastSun { jumped = true }
            last = now
            lastSun = world.sun
        }
        #expect(jumped)
        let settled = world.skyLight(at: crossing.opens + 1)
        #expect(settled.night == world.sun.night)
    }

    /// Held in the middle of one, it stays exactly where it was and carries on afterwards.
    @Test func aHoldStopsTheCloudWhereItIs() throws {
        let world = world()
        let crossing = try flyToCrossing(world)
        let t = crossing.start + 12
        world.advance(to: t)
        let held = world.crossingCloud(at: world.time)
        world.hold(true, at: t)
        world.advance(to: t + 500)
        #expect(world.crossingCloud(at: world.renderTime(for: t + 500))?.closure == held?.closure)
        world.hold(false, at: t + 500)
        world.advance(to: t + 510)
        #expect(try #require(world.crossingCloud(at: world.time)).closure > held!.closure)
    }

    /// Going back to a painting from before the cloud came leaves a clear sky, and the crossing still happens. Past the
    /// change of land there is no going back.
    @Test func goingBackToAPaintingMeetsTheCrossingAgain() throws {
        let world = world()
        var time = 0.0
        var moment: World.Moment?
        while !world.crossingUnderWay, time < 4000 {
            time += 1
            moment = world.moment()
            world.advance(to: time)
        }
        let crossing = try #require(world.journey.crossing)
        let painted = try #require(moment)
        let inCloud = crossing.start + 10
        world.advance(to: inCloud)
        world.hold(true, at: inCloud)
        #expect(world.canRewind(to: painted))
        world.rewind(to: painted)
        #expect(world.crossingCloud(at: world.time) == nil)
        world.hold(false, at: inCloud)
        let before = world.journey.legs.last!.index
        var t = inCloud
        while t < inCloud + 80 {
            t += 0.5
            world.advance(to: t)
        }
        #expect(world.journey.legs.last!.index == before + 1)
        world.hold(true, at: t)
        #expect(!world.canRewind(to: painted))
    }
}
