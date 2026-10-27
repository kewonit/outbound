import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// A display nobody can see keeping its ground up with the flight (`ViewRenderer.keepUp`), so the first frame back
/// paints a strip rather than the whole cache, and never paints the whole cache itself.
@MainActor
@Suite(.serialized)
struct KeepUpTests {
    let gpu = Bench.shared.gpu
    static let view = CGRect(x: 0, y: 0, width: 400, height: 300)
    /// The cache for that view at one texel a point: the view, a margin of two texels and one more on each side.
    static let wholeCache = (400 + 6) * (300 + 6)

    @Test func keepingUpLeavesAStripForTheFirstFrameBack() throws {
        let (world, renderer) = try make()
        try frame(renderer, world, at: 10)
        for t in stride(from: 12.0, through: 100, by: 2) { try keepUp(renderer, world, at: t) }
        try frame(renderer, world, at: 101)
        #expect(renderer.paintedTexels < Self.wholeCache / 4, "painted \(renderer.paintedTexels)")

        // Without keeping up, the same minute and a half away repaints the whole cache.
        let (other, plain) = try make()
        try frame(plain, other, at: 10)
        try frame(plain, other, at: 101)
        #expect(plain.paintedTexels == Self.wholeCache)
    }

    @Test func aFlyToNoFrameSawIsRepaintedAsAWave() throws {
        let (world, renderer) = try make()
        try frame(renderer, world, at: 10)
        world.advance(to: 11)
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: Place.all[1], from: bottom, time: world.time)
        // Mid-sweep, nothing is painted unseen; by the next call the sweep has come and gone.
        try keepUp(renderer, world, at: 12)
        try keepUp(renderer, world, at: 14)
        #expect(renderer.isRepainting(for: world), "the old place is still in the cache")

        // The wave reaches the bottom within a screen of travel.
        var t = 14.0
        while renderer.isRepainting(for: world), t < 40 {
            t += 1.0 / 30
            try frame(renderer, world, at: t)
        }
        #expect(!renderer.isRepainting(for: world), "still repainting at \(t)")
    }

    @Test func keepingUpNeverPaintsTheWholeCache() throws {
        let (world, renderer) = try make()
        try frame(renderer, world, at: 10)
        renderer.invalidate()
        try keepUp(renderer, world, at: 12)
        // Left for the first frame back, which paints it all.
        try frame(renderer, world, at: 13)
        #expect(renderer.paintedTexels == Self.wholeCache)
    }

    // MARK: - Helpers

    private func make() throws -> (World, ViewRenderer) {
        gpu.paintBudget = PaintBudget()
        let noon = Date(timeIntervalSince1970: 1_782_907_200)
        let world = World(place: .first, time: 0, date: noon, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.now = { noon }
        world.home = Self.view
        world.desktop = Self.view
        world.centreRiver(on: Self.view)
        let renderer = ViewRenderer(gpu: gpu)
        renderer.configure(frame: Self.view, scale: 1)
        return (world, renderer)
    }

    private func frame(_ renderer: ViewRenderer, _ world: World, at t: TimeInterval) throws {
        world.advance(to: t)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat, width: 400,
                                                                  height: 300, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let target = try #require(gpu.device.makeTexture(descriptor: descriptor))
        let commands = try #require(gpu.queue.makeCommandBuffer())
        renderer.encode(world: world, at: world.renderTime(for: t), into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func keepUp(_ renderer: ViewRenderer, _ world: World, at t: TimeInterval) throws {
        world.advance(to: t)
        let commands = try #require(gpu.queue.makeCommandBuffer())
        renderer.keepUp(world: world, at: world.renderTime(for: t), commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }
}
