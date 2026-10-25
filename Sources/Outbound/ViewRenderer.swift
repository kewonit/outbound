import CoreGraphics
import Metal
import OutboundCore
import simd

/// Shared Metal objects.
@MainActor
final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let shaders: ShaderLibrary
    let wrap: MTLSamplerState
    let clamp: MTLSamplerState
    /// A small random lattice, so value noise in the frame pass is one texture fetch.
    let noise: MTLTexture

    init() throws {
        // The frame pass reads the framebuffer in the shader and keeps its light in tile memory, which only
        // Apple's own GPUs can do.
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Outbound needs a Mac with Apple silicon."
            ])
        }
        self.device = device
        self.queue = queue
        shaders = try ShaderLibrary(device: device)

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        wrap = device.makeSamplerState(descriptor: descriptor)!
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        clamp = device.makeSamplerState(descriptor: descriptor)!

        let lattice = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 256,
                                                               mipmapped: false)
        lattice.usage = .shaderRead
        lattice.storageMode = .shared
        noise = device.makeTexture(descriptor: lattice)!
        var random = SplitMix(seed: 150)
        let bytes = (0..<(256 * 256)).map { _ in UInt8(random.next() * 255) }
        noise.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256)
    }
}

/// Draws one display's view of the world. The ground is painted into a texture that wraps around
/// in both directions; as the camera moves only the newly revealed rows and columns are painted,
/// and every frame just samples it and adds what moves on top.
@MainActor
final class ViewRenderer {
    private static let pad = 2

    private let gpu: GPU
    /// The view in global desktop points.
    private(set) var frame = CGRect.zero
    private var scale = 1.0
    /// Ground texels per point.
    private var density = 1.0
    private var color: MTLTexture?
    private var mask: MTLTexture?
    private var clouds: MTLTexture?
    private var cacheWidth = 0
    private var cacheHeight = 0
    /// World texel index of the cache's first column and row, nil when nothing valid is cached.
    private var valid: (x: Int, y: Int)?
    private var revision = -1
    /// The next cache row down that a repaint wave still has to reach.
    private var repaintRow: Int?
    /// Leading edge of a Fly To repaint at the last frame, to repaint only the band it swept since.
    private var lastSweepFront: Double?
    /// Cloud-space position of the cloud texture's bottom-left corner when it was last painted.
    private var cloudCorner: SIMD2<Double>?
    private static let cloudMargin = 48
    private var paper: MTLTexture?
    private var paperDirty = true
    /// Kept for the power policy; clouds are already only repainted every few seconds.
    var halfRateClouds = false
    /// Paper grain and edge strength.
    var finish = SIMD4<Float>(1, 0.3, 0, 0)
    /// Half the bird's wingspan, in points.
    var birdSize = 27.0
    /// Draw the bird into the frame, for stills and exports; live it has a layer of its own.
    var drawsBird = true

    init(gpu: GPU) {
        self.gpu = gpu
    }

    func configure(frame: CGRect, scale: Double) {
        guard frame != self.frame || scale != self.scale else { return }
        self.frame = frame
        self.scale = scale
        density = scale
        cacheWidth = Int((Double(frame.width) * density).rounded(.up)) + Self.pad * 2 + 2
        cacheHeight = Int((Double(frame.height) * density).rounded(.up)) + Self.pad * 2 + 2
        color = makeTexture(width: cacheWidth, height: cacheHeight, label: "Ground")
        mask = makeTexture(width: cacheWidth, height: cacheHeight, label: "Ground at night",
                           format: ShaderLibrary.nightFormat)
        let pixelWidth = Int((Double(frame.width) * scale).rounded())
        let pixelHeight = Int((Double(frame.height) * scale).rounded())
        clouds = makeTexture(width: max(pixelWidth / 4, 1) + Self.cloudMargin * 2,
                             height: max(pixelHeight / 4, 1) + Self.cloudMargin * 2, label: "Clouds")
        paper = makeTexture(width: max(pixelWidth / 2, 1), height: max(pixelHeight / 2, 1), label: "Paper",
                            format: ShaderLibrary.paperFormat)
        paperDirty = true
        cloudCorner = nil
        valid = nil
    }

    func invalidate() {
        valid = nil
        cloudCorner = nil
        paperDirty = true
    }

    private func makeTexture(width: Int, height: Int, label: String,
                             format: MTLPixelFormat = ShaderLibrary.cacheFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = gpu.device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    func encode(world: World, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let color, let mask, let clouds else { return }
        let mpp = World.metresPerPoint
        let texel = mpp / density
        let camera = world.camera
        let x0 = Double(frame.minX) * mpp + camera.x
        let y0 = Double(frame.minY) * mpp + camera.y
        let top = Double(frame.maxY) * mpp + camera.y
        let worldFrame = world.frame(bottom: y0, top: top)
        var scene = worldFrame.scene

        // Work out which world texel rectangles need painting.
        let need = (x: Int((x0 / texel).rounded(.down)) - Self.pad, y: Int((y0 / texel).rounded(.down)) - Self.pad)
        // A finished Fly To repaints once more in full, so every row ends up in the new place.
        var full = valid == nil || (lastSweepFront != nil && worldFrame.sweepFront == nil)
        // Anything else baked into the ground changing (the sun moving on, a new season) is repainted as a wave
        // from top to bottom over about half a second, so no single frame has to repaint the whole screen.
        if revision != world.revision {
            repaintRow = valid == nil ? nil : (valid!.y + cacheHeight)
            cloudCorner = nil
        }
        var rects: [(x: Int, y: Int, w: Int, h: Int)] = []
        if !full, let v = valid {
            let dx = need.x - v.x, dy = need.y - v.y
            if abs(dx) >= cacheWidth || abs(dy) >= cacheHeight {
                full = true
            } else {
                if dy > 0 { rects.append((need.x, v.y + cacheHeight, cacheWidth, dy)) }
                if dy < 0 { rects.append((need.x, need.y, cacheWidth, -dy)) }
                let keptY = max(need.y, v.y), keptH = cacheHeight - abs(dy)
                if dx > 0 { rects.append((v.x + cacheWidth, keptY, dx, keptH)) }
                if dx < 0 { rects.append((need.x, keptY, -dx, keptH)) }
            }
        }
        if full {
            rects = [(need.x, need.y, cacheWidth, cacheHeight)]
        }
        if !full, let wave = repaintRow {
            let row = min(wave, need.y + cacheHeight)
            let band = max(cacheHeight / 12, 1)
            let low = max(row - band, need.y)
            if low < row { rects.append((need.x, low, cacheWidth, row - low)) }
            repaintRow = low > need.y ? low : nil
        } else if full {
            repaintRow = nil
        }
        if !full, let front = worldFrame.sweepFront {
            // Only the band the wave crossed since the last frame changes; 400 m is its soft edge.
            let from = min(lastSweepFront ?? front, front) - 420
            let rowStart = max(Int((from / texel).rounded(.down)), need.y)
            let rowEnd = min(Int(((front + 20) / texel).rounded(.up)), need.y + cacheHeight)
            if rowEnd > rowStart { rects.append((need.x, rowStart, cacheWidth, rowEnd - rowStart)) }
        }
        valid = need
        revision = world.revision
        lastSweepFront = worldFrame.sweepFront

        let pipelines = gpu.shaders.pipelines
        if !rects.isEmpty {
            let pass = MTLRenderPassDescriptor()
            for (i, texture) in [color, mask].enumerated() {
                pass.colorAttachments[i].texture = texture
                pass.colorAttachments[i].loadAction = full ? .dontCare : .load
                pass.colorAttachments[i].storeAction = .store
            }
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Ground"
                encoder.setRenderPipelineState(pipelines.ground)
                encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
                for rect in rects {
                    for piece in pieces(rect) {
                        var params = GroundGPU(
                            origin: SIMD4(Float(piece.tx), Float(piece.ty), Float(Double(piece.wx) * texel),
                                          Float(Double(piece.wy) * texel - worldFrame.reference)),
                            texel: SIMD4(Float(texel), 0, 0, 0))
                        encoder.setScissorRect(MTLScissorRect(x: piece.tx, y: piece.ty, width: piece.w, height: piece.h))
                        encoder.setFragmentBytes(&params, length: MemoryLayout<GroundGPU>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }
                encoder.endEncoding()
            }
        }

        // Clouds never change shape, they only drift, so they are painted at a quarter of the resolution
        // with a margin and slid along until the margin runs out.
        let metresPerPixel = mpp / scale
        let cloudPixel = metresPerPixel * 4
        let origin = SIMD2(Double(frame.minX), Double(frame.minY)) * mpp
        let viewCloud = world.cloudSpace(origin)
        var offset = cloudCorner.map { Self.wrapped(viewCloud - $0) } ?? .zero
        let marginMetres = Double(Self.cloudMargin) * cloudPixel
        if cloudCorner == nil || full || offset.x < 0 || offset.y < 0
            || offset.x > marginMetres * 2 || offset.y > marginMetres * 2 {
            let corner = viewCloud - SIMD2(marginMetres, marginMetres)
            let toSun = SIMD2<Double>(Double(scene.sun.x), Double(scene.sun.y))
            var cloudParams = CloudsGPU(
                origin: SIMD4(Float(corner.x.positiveRemainder(16384)), Float(corner.y.positiveRemainder(16384)),
                              Float(cloudPixel), Float(world.cloudCover)),
                offsets: SIMD4(Float(toSun.x * 26), Float(toSun.y * 26), Float(toSun.x * World.cloudHeight),
                               Float(toSun.y * World.cloudHeight)),
                view: SIMD4(Float(clouds.height), 0, 0, 0))
            let cloudPass = MTLRenderPassDescriptor()
            cloudPass.colorAttachments[0].texture = clouds
            cloudPass.colorAttachments[0].loadAction = .dontCare
            cloudPass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: cloudPass) {
                encoder.label = "Clouds"
                encoder.setRenderPipelineState(pipelines.clouds)
                encoder.setFragmentBytes(&cloudParams, length: MemoryLayout<CloudsGPU>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            cloudCorner = corner
            offset = SIMD2(marginMetres, marginMetres)
        }

        if paperDirty, let paper {
            var paperParams = SIMD4<Float>(Float(target.width), Float(target.height), 0.5, 0)
            let paperPass = MTLRenderPassDescriptor()
            paperPass.colorAttachments[0].texture = paper
            paperPass.colorAttachments[0].loadAction = .dontCare
            paperPass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: paperPass) {
                encoder.label = "Paper"
                encoder.setRenderPipelineState(pipelines.paper)
                encoder.setFragmentBytes(&paperParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                paperDirty = false
            }
        }

        // Composite into the target. The bird is drawn by whichever display it is over.
        let gust = world.gustSpace(origin)
        let bird = world.bird
        let birdPoint = bird.position - SIMD2(Double(frame.minX), Double(frame.minY))
        let birdVisible = birdPoint.x > -90 && birdPoint.y > -90
            && birdPoint.x < Double(frame.width) + 90 && birdPoint.y < Double(frame.height) + 90
        var finish = self.finish
        finish.z = drawsBird ? 1 : 0
        var params = CompositeGPU(
            view: SIMD4(Float(target.width), Float(target.height), Float(metresPerPixel), Float(density / scale)),
            world: SIMD4(Float(x0), Float(y0 - worldFrame.reference), Float(gust.x), Float(gust.y)),
            cache: SIMD4(Float((x0 / texel).positiveRemainder(Double(cacheWidth))),
                         Float((y0 / texel).positiveRemainder(Double(cacheHeight))),
                         Float(cacheWidth), Float(cacheHeight)),
            bird: SIMD4(Float(birdPoint.x * scale), Float(birdPoint.y * scale), Float(bird.heading - .pi / 2),
                        Float(bird.bank)),
            wings: SIMD4(Float(bird.wings), 14, Float(birdSize * scale), birdVisible ? 1 : 0),
            finish: finish,
            clouds: SIMD4(Float(offset.x), Float(offset.y), Float(cloudPixel), 0),
            flock: .zero, flockShape: .zero, flockLook: .zero)
        if let (flock, sighting) = world.flock {
            let point = sighting.position - SIMD2(Double(frame.minX), Double(frame.minY))
            let reach = flock.size * Double(flock.count) * 3 + 300
            if point.x > -reach, point.y > -reach, point.x < Double(frame.width) + reach,
               point.y < Double(frame.height) + reach {
                params.flock = SIMD4(Float(point.x * scale), Float(point.y * scale), Float(sighting.heading), 1)
                // Shadows fall altitude x shadow length metres from the birds, in pixels.
                params.flockShape = SIMD4(Float(flock.formation.rawValue), Float(flock.count), Float(flock.size * scale),
                                          Float(flock.altitude / metresPerPixel))
                params.flockLook = SIMD4(flock.color, Float(sighting.time))
            }
        }
        // One pass: ground, animals, then sky, with the night's light kept in tile memory between them.
        let light = lightTarget(width: target.width, height: target.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = light
        pass.colorAttachments[1].loadAction = .dontCare
        pass.colorAttachments[1].storeAction = .dontCare
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Frame"
            encoder.setFragmentBytes(&params, length: MemoryLayout<CompositeGPU>.stride, index: 0)
            encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
            encoder.setFragmentTexture(color, index: 0)
            encoder.setFragmentTexture(mask, index: 1)
            encoder.setFragmentTexture(clouds, index: 2)
            encoder.setFragmentTexture(paper, index: 3)
            encoder.setFragmentTexture(gpu.noise, index: 4)
            encoder.setFragmentSamplerState(gpu.wrap, index: 0)
            encoder.setFragmentSamplerState(gpu.clamp, index: 1)
            encoder.setRenderPipelineState(pipelines.view)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            let batches = animalBatches(world: world, frame: worldFrame, x0: x0, x1: x0 + Double(frame.width) * mpp,
                                        y0: y0, top: top)
            if !batches.isEmpty {
                encoder.setRenderPipelineState(pipelines.animals)
                encoder.setVertexBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 2)
                encoder.setVertexBytes(&params, length: MemoryLayout<CompositeGPU>.stride, index: 3)
                encoder.setVertexTexture(color, index: 0)
                for var batch in batches {
                    var leg = batch.leg
                    encoder.setVertexBytes(&batch.params, length: MemoryLayout<AnimalsGPU>.stride, index: 0)
                    encoder.setVertexBytes(&leg, length: MemoryLayout<LegGPU>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
                }
            }

            encoder.setRenderPipelineState(pipelines.sky)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private var light: MTLTexture?

    /// The night's light between the draws of the frame pass. Memoryless: it only ever exists in tile memory.
    private func lightTarget(width: Int, height: Int) -> MTLTexture? {
        if let light, light.width == width, light.height == height { return light }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.lightFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .memoryless
        light = gpu.device.makeTexture(descriptor: descriptor)
        return light
    }

    private struct AnimalBatch {
        var params: AnimalsGPU
        var leg: LegGPU
        var count: Int
    }

    /// Herds are drawn as instanced sprites, one instance per cell of each visible leg's herd grid.
    private func animalBatches(world: World, frame: World.Frame, x0: Double, x1: Double, y0: Double,
                               top: Double) -> [AnimalBatch] {
        var regions: [(leg: Leg, gpu: LegGPU, low: Double, high: Double)] = []
        if frame.legA.index == frame.legB.index {
            regions.append((frame.legB, frame.scene.legB, -.infinity, .infinity))
        } else {
            let split = frame.legB.start + Journey.morphLength * 0.5
            regions.append((frame.legA, frame.scene.legA, -.infinity, split))
            regions.append((frame.legB, frame.scene.legB, split, .infinity))
        }
        var batches: [AnimalBatch] = []
        for region in regions {
            let biome = region.leg.season.biome
            guard biome.animal != .none, biome.herds > 0 else { continue }
            let low = max(y0, region.low), high = min(top, region.high)
            guard high > low else { continue }
            let spacing: Double = [Biome.Animal.zebra, .wildebeest, .gazelle].contains(biome.animal) ? 9 : 10
            let drift = World.herdDrift(time: world.time, seed: UInt32(region.gpu.info.y))
            let margin = 6.0
            let cx0 = Int(((x0 - margin - drift.x) / spacing).rounded(.down))
            let cx1 = Int(((x1 + margin - drift.x) / spacing).rounded(.down))
            let cy0 = Int(((low - region.leg.start - margin - drift.y) / spacing).rounded(.down))
            let cy1 = Int(((high - region.leg.start + margin - drift.y) / spacing).rounded(.down))
            let across = cx1 - cx0 + 1, rows = cy1 - cy0 + 1
            guard across > 0, rows > 0 else { continue }
            let clampLow = region.low.isFinite ? Float(region.low - frame.reference) : -1e9
            let clampHigh = region.high.isFinite ? Float(region.high - frame.reference) : 1e9
            batches.append(AnimalBatch(
                params: AnimalsGPU(grid: SIMD4(Float(cx0), Float(cy0), Float(across), Float(spacing)),
                                   leg: SIMD4(Float(region.leg.start - frame.reference), clampLow, clampHigh, 0),
                                   drift: SIMD4(Float(drift.x), Float(drift.y), 0, 0)),
                leg: region.gpu, count: across * rows))
        }
        return batches
    }

    /// The shortest offset between two points of the repeating cloud space.
    private static func wrapped(_ d: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((d.x + 8192).positiveRemainder(16384) - 8192, (d.y + 8192).positiveRemainder(16384) - 8192)
    }

    /// Paints the bird alone into the small layer that follows it, `size` points square around its centre.
    func encodeBird(world: World, into target: MTLTexture, commandBuffer: MTLCommandBuffer, size: Double, scale: Double) {
        let bird = world.bird
        let centre = Float(size * scale * 0.5)
        var params = CompositeGPU(
            view: SIMD4(Float(target.width), Float(target.height), Float(World.metresPerPoint / scale), 0),
            world: .zero, cache: .zero,
            bird: SIMD4(centre, centre, Float(bird.heading - .pi / 2), Float(bird.bank)),
            wings: SIMD4(Float(bird.wings), 14, Float(birdSize * scale), 1),
            finish: .zero, clouds: .zero, flock: .zero, flockShape: .zero, flockLook: .zero)
        var scene = world.frame(bottom: world.camera.y, top: world.camera.y + 1).scene
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Bird"
        encoder.setRenderPipelineState(gpu.shaders.pipelines.bird)
        encoder.setFragmentBytes(&params, length: MemoryLayout<CompositeGPU>.stride, index: 0)
        encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Splits a world texel rectangle where it wraps around the cache's edges.
    private func pieces(_ rect: (x: Int, y: Int, w: Int, h: Int)) -> [(tx: Int, ty: Int, w: Int, h: Int, wx: Int, wy: Int)] {
        var out: [(tx: Int, ty: Int, w: Int, h: Int, wx: Int, wy: Int)] = []
        var y = rect.y
        var remainingH = rect.h
        while remainingH > 0 {
            let ty = y.positiveRemainder(cacheHeight)
            let h = min(remainingH, cacheHeight - ty)
            var x = rect.x
            var remainingW = rect.w
            while remainingW > 0 {
                let tx = x.positiveRemainder(cacheWidth)
                let w = min(remainingW, cacheWidth - tx)
                out.append((tx, ty, w, h, x, y))
                x += w
                remainingW -= w
            }
            y += h
            remainingH -= h
        }
        return out
    }
}

/// Small deterministic random numbers.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
