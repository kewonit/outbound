import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// More than one display: each is a window on the one landscape, and a Fly To turns all of them.
@MainActor
@Suite(.serialized)
struct DisplaysTests {
    /// Displays in global desktop points, the main one first, as NSScreen lists them.
    struct Layout: Sendable, CustomTestStringConvertible {
        let name: String
        let frames: [CGRect]
        var testDescription: String { name }
    }

    nonisolated static let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    nonisolated static let layouts = [
        Layout(name: "an ultrawide above", frames: [main, CGRect(x: -1048, y: 982, width: 2560, height: 1080)]),
        Layout(name: "a taller one to the left, tops level",
               frames: [main, CGRect(x: -2560, y: -458, width: 2560, height: 1440)]),
        Layout(name: "one below", frames: [main, CGRect(x: -200, y: -1080, width: 1920, height: 1080)]),
        Layout(name: "a lower one to the right", frames: [main, CGRect(x: 1512, y: -700, width: 1920, height: 1080)]),
        Layout(name: "three", frames: [main, CGRect(x: -1048, y: 982, width: 2560, height: 1080),
                                       CGRect(x: 1512, y: -300, width: 1080, height: 1920)]),
    ]

    private func world(_ frames: [CGRect], seconds: Double) -> World {
        let date = Date(timeIntervalSince1970: 1_782_907_200)
        let world = World(place: Place.named("normandy")!, time: 0, date: date, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.now = { date }
        world.desktop = frames.reduce(CGRect.null) { $0.union($1) }
        world.home = frames[0]
        world.centreRiver(on: frames[0])
        world.advance(to: seconds)
        return world
    }

    /// Picks the next place from the menu, as the app does, and hands it back. With `atOnce` it is there already.
    @discardableResult
    private func flyOn(_ world: World, atOnce: Bool = false) -> Place {
        let here = world.journey.leg(at: world.camera.y).place
        let next = Place.all[((Place.all.firstIndex { $0.id == here.id } ?? 0) + 1) % Place.all.count]
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: next, from: bottom, time: world.time, atOnce: atOnce)
        return next
    }

    /// The world bottom and top of a display's view at `t`.
    private func view(_ world: World, _ display: CGRect, at t: TimeInterval) -> (bottom: Double, top: Double) {
        let y = world.camera(at: t).y
        return (y + Double(display.minY) * World.metresPerPoint, y + Double(display.maxY) * World.metresPerPoint)
    }

    private func frame(_ world: World, on display: CGRect, at t: TimeInterval) -> World.Frame {
        let view = view(world, display, at: t)
        return world.frame(bottom: view.bottom, top: view.top, at: t)
    }

    /// Whether all a display shows at `t` is `place`: the view lies wholly over its leg, with no sweep under way.
    private func showsOnly(_ place: Place, _ world: World, on display: CGRect, at t: TimeInterval) -> Bool {
        let frame = frame(world, on: display, at: t)
        return frame.sweepFront == nil && frame.legB.place.id == place.id
            && (frame.legA.index == frame.legB.index || frame.legB.start <= view(world, display, at: t).bottom)
    }

    @Test(arguments: layouts)
    func aFlyToTurnsEveryDisplayUnderOneFront(_ layout: Layout) throws {
        let world = world(layout.frames, seconds: 120)
        let before = world.journey.leg(at: world.camera.y).place
        let next = flyOn(world)
        let start = world.time
        for step in 1...7 {
            let t = start + Double(step) * 0.2
            world.advance(to: t)
            let frames = layout.frames.map { frame(world, on: $0, at: t) }
            for (display, frame) in zip(layout.frames, frames) {
                #expect(frame.sweepFront != nil, "\(display) at \(step)")
                #expect(frame.legA.place.id == before.id, "\(display) at \(step)")
                #expect(frame.legB.place.id == next.id, "\(display) at \(step)")
            }
            // One front, so the land turns alike either side of any edge where two displays meet.
            let first = try #require(frames.first)
            for frame in frames.dropFirst() {
                #expect(frame.scene.morph.x == first.scene.morph.x)
                #expect(frame.scene.morph.z == first.scene.morph.z)
                #expect(frame.scene.morph.w == first.scene.morph.w)
                #expect(frame.sweepFront == first.sweepFront)
            }
        }
        // Far enough by the end to have passed over the top of the highest display.
        let end = start + Journey.sweepDuration - 0.01
        let top = layout.frames.map { view(world, $0, at: end).top }.max()!
        #expect(try #require(frame(world, on: layout.frames[0], at: end).sweepFront) > top)
        world.advance(to: start + 1.7)
        for display in layout.frames {
            #expect(showsOnly(next, world, on: display, at: world.time), "\(display)")
            let middle = world.camera.y + Double(display.midY) * World.metresPerPoint
            #expect(world.journey.placeShown(at: middle, time: world.time).id == next.id)
        }
    }

    /// A display unplugged or plugged in while a sweep is under way takes nothing of the front with it, nor brings
    /// anything: the others carry on turning just as they were.
    @Test func aDisplayComingOrGoingMidSweepLeavesTheFrontAlone() throws {
        let layout = Self.layouts[0]
        let world = world(layout.frames, seconds: 120)
        flyOn(world)
        let t = world.time + 0.6
        world.advance(to: t)
        let before = frame(world, on: layout.frames[0], at: t)
        #expect(before.sweepFront != nil)
        world.desktop = layout.frames[0]
        let gone = frame(world, on: layout.frames[0], at: t)
        #expect(gone.sweepFront == before.sweepFront)
        #expect(gone.scene.morph.w == before.scene.morph.w)
        world.desktop = layout.frames.reduce(CGRect.null) { $0.union($1) }.union(CGRect(x: 0, y: 2062, width: 900, height: 900))
        #expect(frame(world, on: layout.frames[0], at: t).sweepFront == before.sweepFront)
        // The next Fly To sweeps over the desktop as it is by then.
        flyOn(world)
        let next = frame(world, on: layout.frames[0], at: world.time + 0.6)
        let top = world.camera(at: world.time + 0.6).y + 2962 * World.metresPerPoint
        #expect(abs(Double(next.scene.morph.w) - (top - next.legB.start)) < 0.01)
    }

    /// So soon after a fresh launch that the first place starts above the bottom of a display below the main one, the
    /// new place has nothing to turn out of: every display shows it at once.
    @Test func aFlyToJustAfterLaunchWithADisplayBelow() {
        let layout = Self.layouts[2]
        let world = world(layout.frames, seconds: 5)
        let next = flyOn(world)
        world.advance(to: world.time + 0.1)
        for display in layout.frames { #expect(showsOnly(next, world, on: display, at: world.time), "\(display)") }
    }

    // MARK: - Drawn

    /// Small displays, so drawing them is quick, laid out as on the Mac this was found on: a wider one above the main
    /// one and to its left, its bottom well over 200 m above the line the new place starts on.
    nonisolated static let drawnAbove = [CGRect(x: 0, y: 0, width: 720, height: 450),
                                         CGRect(x: -500, y: 450, width: 1220, height: 320)]
    /// One below the main one, as tall as to reach under where the first place starts just after launch.
    nonisolated static let drawnBelow = [CGRect(x: 0, y: 0, width: 720, height: 450),
                                         CGRect(x: -100, y: -900, width: 900, height: 900)]

    private func target(_ display: CGRect, gpu: GPU) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: ShaderLibrary.viewFormat, width: Int(display.width), height: Int(display.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(gpu.device.makeTexture(descriptor: descriptor))
    }

    private func renderer(_ display: CGRect, gpu: GPU) -> ViewRenderer {
        let renderer = ViewRenderer(gpu: gpu)
        renderer.waitsForPieces = true
        renderer.leanShaders = false
        renderer.configure(frame: display, scale: 1)
        return renderer
    }

    /// Draws `display`'s view at `t` with `renderer` and reads it back.
    private func draw(_ renderer: ViewRenderer, _ world: World, _ display: CGRect, at t: TimeInterval,
                      gpu: GPU) throws -> [UInt8] {
        let target = try target(display, gpu: gpu)
        let commands = try #require(gpu.queue.makeCommandBuffer())
        renderer.encode(world: world, at: t, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.error == nil)
        let width = target.width, height = target.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    /// The share of pixels where any channel differs by more than a few levels. Clouds slid along since they were
    /// painted come out a level or two off ones painted afresh; two different places differ almost everywhere.
    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var count = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            if (0..<3).contains(where: { abs(Int(a[pixel + $0]) - Int(b[pixel + $0])) > 24 }) { count += 1 }
        }
        return Double(count) / Double(a.count / 4)
    }

    /// Flies to the next place with each display drawing at 30 frames a second, or not at all through the sweep where
    /// `drawsDuring` says not, then checks each display shows just what one painted afresh does. Each display in
    /// `turning` must be caught three quarters of the way through with the new place only partly in: unlike both the
    /// old place and the new one at that moment, which two more worlds show, one not flown anywhere and one already
    /// there.
    private func flyAndCompare(_ frames: [CGRect], seconds: Double, drawsDuring: [Bool],
                               turning: Set<Int> = []) throws {
        let gpu = try GPU()
        let world = world(frames, seconds: seconds)
        let stayed = self.world(frames, seconds: seconds), there = self.world(frames, seconds: seconds)
        let renderers = frames.map { renderer($0, gpu: gpu) }
        let before = try zip(renderers, frames).map { try draw($0, world, $1, at: world.time, gpu: gpu) }
        flyOn(world)
        flyOn(there, atOnce: true)
        let start = world.time
        var t = start
        var checked: Set<Int> = []
        while t < start + Journey.sweepDuration + 0.4 {
            t += 1.0 / 30
            for each in [world, stayed, there] { each.advance(to: t) }
            for i in frames.indices where drawsDuring[i] {
                let drawn = try draw(renderers[i], world, frames[i], at: t, gpu: gpu)
                guard turning.contains(i), !checked.contains(i), t - start >= Journey.sweepDuration * 0.75 else { continue }
                checked.insert(i)
                let old = try draw(renderer(frames[i], gpu: gpu), stayed, frames[i], at: t, gpu: gpu)
                let new = try draw(renderer(frames[i], gpu: gpu), there, frames[i], at: t, gpu: gpu)
                #expect(differing(drawn, old) > 0.05, "display \(i): \(differing(drawn, old))")
                #expect(differing(drawn, new) > 0.05, "display \(i): \(differing(drawn, new))")
            }
        }
        #expect(checked == turning)
        for i in frames.indices {
            let kept = try draw(renderers[i], world, frames[i], at: t, gpu: gpu)
            let afresh = try draw(renderer(frames[i], gpu: gpu), world, frames[i], at: t, gpu: gpu)
            // The new place really is another picture, so a display left on the old one can't pass.
            #expect(differing(before[i], afresh) > 0.3, "display \(i)")
            #expect(differing(kept, afresh) < 0.01, "display \(i): \(differing(kept, afresh))")
        }
    }

    /// The display above turns as the main one does, the new place spreading up into it, rather than changing at once.
    @Test func everyDisplayDrawsTheNewPlace() throws {
        try flyAndCompare(Self.drawnAbove, seconds: 120, drawsDuring: [true, true], turning: [1])
    }

    /// Covered by a full-screen app, say, while the new place swept in elsewhere.
    @Test func aDisplayThatDrewNothingThroughTheSweepCatchesUp() throws {
        try flyAndCompare(Self.drawnAbove, seconds: 120, drawsDuring: [true, false])
    }

    @Test func aFlyToJustAfterLaunchWithADisplayBelowIsDrawnOnBoth() throws {
        try flyAndCompare(Self.drawnBelow, seconds: 5, drawsDuring: [true, true])
    }
}
