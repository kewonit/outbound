import CoreGraphics
import Metal
import simd

/// Shared Metal objects.
@MainActor
final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let shaders: ShaderLibrary
    let wrap: MTLSamplerState
    let clamp: MTLSamplerState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
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
        mask = makeTexture(width: cacheWidth, height: cacheHeight, label: "Ground mask")
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
        var full = valid == nil || revision != world.revision || (lastSweepFront != nil && worldFrame.sweepFront == nil)
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
        } else if let front = worldFrame.sweepFront {
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
            clouds: SIMD4(Float(offset.x), Float(offset.y), Float(cloudPixel), 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Composite"
            encoder.setRenderPipelineState(pipelines.composite)
            encoder.setFragmentBytes(&params, length: MemoryLayout<CompositeGPU>.stride, index: 0)
            encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
            encoder.setFragmentTexture(color, index: 0)
            encoder.setFragmentTexture(mask, index: 1)
            encoder.setFragmentTexture(clouds, index: 2)
            encoder.setFragmentTexture(paper, index: 3)
            encoder.setFragmentSamplerState(gpu.wrap, index: 0)
            encoder.setFragmentSamplerState(gpu.clamp, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    /// The shortest offset between two points of the repeating cloud space.
    private static func wrapped(_ d: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((d.x + 8192).positiveRemainder(16384) - 8192, (d.y + 8192).positiveRemainder(16384) - 8192)
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
