import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// Coming back to a display that was hidden: its first frames dissolve from what it showed (`ViewRenderer.encode`'s
/// overlay), which has to start from exactly that picture, or the dissolve would begin with a flash.
@MainActor
@Suite(.serialized)
struct DissolveTests {
    let gpu = Bench.shared.gpu
    static let view = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func theFirstFrameBackIsExactlyWhatWasShown() throws {
        let (world, renderer) = try make()
        let then = try target()
        try frame(renderer, world, at: 70, into: then)
        let was = bytes(then)
        let now = try target()
        try frame(renderer, world, at: 71, into: now)
        let plain = bytes(now)
        #expect(plain != was, "a second of flight should change the view")

        try frame(renderer, world, at: 71, into: now, overlay: (then, 1))
        #expect(bytes(now) == was)
        try frame(renderer, world, at: 71, into: now, overlay: (then, 0))
        #expect(bytes(now) == plain)
        try frame(renderer, world, at: 71, into: now, overlay: (then, 0.5))
        let half = bytes(now)
        let outside = zip(half, zip(was, plain)).filter { value, ends in
            Int(value) < Int(min(ends.0, ends.1)) - 1 || Int(value) > Int(max(ends.0, ends.1)) + 1
        }.count
        #expect(outside == 0)
        #expect(half != was && half != plain)
    }

    @Test func paintingAgainWhatWasShownPaintsNothingThatWaited() throws {
        let (world, renderer) = try make()
        let shown = try target()
        try frame(renderer, world, at: 10, into: shown)
        // Morning light over Kansas, with shadows of its own, repainted as a wave over the frames to come. The place's own
        // time, so it doesn't hang on the time zone the test runs in.
        world.now = { Date(timeIntervalSince1970: 1_782_907_200 + 3.5 * 3600) }
        world.light = .placeTime
        try frame(renderer, world, at: 10 + 1.0 / 30, into: shown)
        #expect(renderer.isRepainting(for: world))
        let last = bytes(shown)

        let again = try target()
        try frame(renderer, world, at: 10 + 1.0 / 30, into: again, paintsWaiting: false)
        #expect(bytes(again) == last)
        #expect(renderer.paintedTexels == 0)
        // Painting what could wait takes the wave further, which the window never showed.
        try frame(renderer, world, at: 10 + 1.0 / 30, into: again)
        #expect(renderer.paintedTexels > 0)
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

    private func target() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat, width: 400,
                                                                  height: 300, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(gpu.device.makeTexture(descriptor: descriptor))
    }

    private func frame(_ renderer: ViewRenderer, _ world: World, at t: TimeInterval, into target: MTLTexture,
                       overlay: (MTLTexture, Float)? = nil, paintsWaiting: Bool = true) throws {
        world.advance(to: t)
        let commands = try #require(gpu.queue.makeCommandBuffer())
        renderer.encode(world: world, at: world.renderTime(for: t), into: target, commandBuffer: commands,
                        overlay: overlay.map { (texture: $0.0, fade: $0.1) }, paintsWaiting: paintsWaiting)
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func bytes(_ texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }
}
