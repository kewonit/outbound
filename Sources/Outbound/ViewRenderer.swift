import CoreGraphics
import Metal
import OutboundCore
import simd

/// Shared Metal objects.
@MainActor
final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    /// The bird's small layer has a queue of its own, so its frames never wait behind a landscape's.
    let birdQueue: MTLCommandQueue
    let shaders: ShaderLibrary
    let wrap: MTLSamplerState
    let clamp: MTLSamplerState
    /// A small random lattice, so value noise in the frame pass is one texture fetch.
    let noise: MTLTexture
    /// What every display together may spend painting ground that can wait.
    var paintBudget: PaintBudget
    /// What painting the ground costs on this GPU, which sets how much of it goes into one piece of GPU work. Kept
    /// for the next launch, so a slow GPU starts in small pieces.
    private(set) var groundCost: GroundCost
    /// The GPU no longer takes Outbound's work, after too much of it ran too long: nothing it draws reaches the screen
    /// again until Outbound starts afresh.
    private(set) var revoked = false
    var onRevoked: () -> Void = {}
    /// The last error the GPU gave and how many there have been, for the feedback page.
    private(set) var lastError: (name: String, count: Int)?
    /// Which failures cut pieces down. Work is stamped with `cuts` as it is sent, and its failing passes that back.
    private var failures = GPUFailures()
    var cuts: Int { failures.cuts }
    /// Since the last failure, or the last step back up after one: pieces grow back once all has gone well a while.
    private var quietSince = Date.now
    /// Command buffers say which of their passes failed only once one has, as asking costs a little on every one.
    private var detailedErrors = false
    private static let costKey = "groundCost"

    init() throws {
        // The frame pass reads the framebuffer in the shader and keeps its light in tile memory, which only
        // Apple's own GPUs can do.
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let queue = device.makeCommandQueue(), let birdQueue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Outbound needs a Mac with Apple silicon."
            ])
        }
        self.device = device
        self.queue = queue
        self.birdQueue = birdQueue
        let saved = (UserDefaults.standard.dictionary(forKey: Self.costKey)?[device.name] as? [String: Double])
            .flatMap { saved in saved["cost"].flatMap { cost in saved["target"].map { (cost, $0) } } }
        // Only what a run could have saved, so a damaged value never stays to trouble every launch.
        groundCost = saved.flatMap { cost, target in
            cost.isFinite && target.isFinite && cost > 0 && target > 0
                ? GroundCost(millisecondsPerMillion: min(max(cost, 0.5), 20_000),
                             target: min(max(target, 1), GroundCost.initial.target))
                : nil
        } ?? .initial
        paintBudget = PaintBudget(costPerMillion: min(max(groundCost.millisecondsPerMillion, 1), 400))
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

    /// A command buffer on the frames' queue that says which of its passes failed, should it fail.
    func commandBuffer() -> MTLCommandBuffer? {
        let descriptor = MTLCommandBufferDescriptor()
        if detailedErrors { descriptor.errorOptions = .encoderExecutionStatus }
        return queue.makeCommandBuffer(descriptor: descriptor)
    }

    /// A piece of ground painting of `texels` took `milliseconds` of GPU time.
    func learn(texels: Int, milliseconds: Double) {
        groundCost.finished(texels: texels, milliseconds: milliseconds)
        paintBudget.learn(milliseconds: milliseconds, painted: texels)
        recoverIfQuiet()
    }

    /// GPU work went well. After ten minutes without a failure, pieces and the painting that can wait, cut down by one,
    /// grow back a step, so one bad moment doesn't slow them for good. Asked by frames as well as pieces, as steady
    /// flying paints few pieces.
    func recoverIfQuiet() {
        guard groundCost.target < GroundCost.initial.target || paintBudget.milliseconds < PaintBudget.usualMilliseconds,
              Date.now.timeIntervalSince(quietSince) > 600 else { return }
        groundCost.recover()
        paintBudget.recover()
        quietSince = .now
        saveCost()
        Log.render.info("Painting in bigger pieces again: \(self.groundCost.texelsPerPiece) texels")
    }

    /// GPU work stamped with `sent` (see `cuts`) failed. Work stopped for running too long, or failing again and
    /// again, means pieces a quarter the size from now on, once for each time it happens (see `GPUFailures`). Refused
    /// outright, the GPU will take nothing more, so nothing more is sent.
    func failed(_ outcome: GPUOutcome, doing what: String, sent: Int) {
        let error = outcome.error as NSError?
        let code = error.flatMap { error in
            error.domain == MTLCommandBufferErrorDomain ? UInt(exactly: error.code).flatMap(MTLCommandBufferError.Code.init) : nil
        }
        let name = switch code {
        case .timeout: "timeout"
        case .accessRevoked: "revoked"
        case .pageFault: "fault"
        case .outOfMemory: "memory"
        case .notPermitted: "refused"
        case .some: "error\(error?.code ?? 0)"
        case nil: "other"
        }
        let count = (lastError?.count ?? 0) + 1
        lastError = (name, count)
        detailedErrors = true
        // Refused already, nothing more is sent but what was on its way, whose failing says nothing new.
        guard !revoked else { return }
        quietSince = .now
        // The first few in full, then now and then, as a GPU in trouble fails every frame.
        if count <= 5 || count % 100 == 0 {
            let faulted = (error?.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] ?? [])
                .filter { $0.errorState == .faulted }.map(\.label).joined(separator: ", ")
            Log.render.error("GPU error \(count) \(what, privacy: .public): \(String(describing: error), privacy: .public) in \(faulted.isEmpty ? "?" : faulted, privacy: .public)")
        }
        let tooLong = code == .timeout || String(describing: error).contains("Interactivity")
        if code == .accessRevoked, !revoked {
            revoked = true
            // What ran too long may not have said so, so the copy that opens next starts in smaller pieces.
            groundCost.backOff()
            saveCost()
            Log.render.error("The GPU takes no more of Outbound's work; \(self.groundCost.texelsPerPiece) texels a piece next time")
            onRevoked()
        } else if failures.failed(sent: sent, tooLong: tooLong, at: ProcessInfo.processInfo.systemUptime) {
            groundCost.backOff()
            paintBudget.backOff()
            saveCost()
            Log.render.error("Painting in smaller pieces: \(self.groundCost.texelsPerPiece) texels")
        }
    }

    /// Keeps what painting costs here for the next launch.
    func saveCost() {
        var all = UserDefaults.standard.dictionary(forKey: Self.costKey) ?? [:]
        all[device.name] = ["cost": groundCost.millisecondsPerMillion, "target": groundCost.target]
        UserDefaults.standard.set(all, forKey: Self.costKey)
    }
}

/// How a command buffer went, read where Metal says so and handed on to the main thread.
struct GPUOutcome: Sendable {
    let completed: Bool
    let milliseconds: Double
    let error: (any Error)?

    init(_ buffer: MTLCommandBuffer) {
        completed = buffer.status == .completed
        milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        error = buffer.error
    }
}

/// Ground to paint, draw by draw, handed out in pieces of GPU work no bigger than asked for. A draw too big for a piece
/// is cut into bands of whole rows, each keeping the draw's own origin, so every texel comes out just as it would
/// have in the one draw.
struct GroundStrokes {
    struct Stroke {
        var params: GroundGPU
        var scissor: MTLScissorRect
        /// Which of the caches it paints: the ground's own, or, during a Fly To, the new place's.
        var into: Int

        var texels: Int { scissor.width * scissor.height }
    }

    private(set) var strokes: [Stroke]

    init(_ strokes: [Stroke]) {
        self.strokes = strokes.filter { $0.texels > 0 }
    }

    var isEmpty: Bool { strokes.isEmpty }
    var texels: Int { strokes.reduce(0) { $0 + $1.texels } }

    /// The next piece: draws for one cache, of `texels` at most, though never less than one row.
    mutating func take(texels: Int) -> [Stroke] {
        var piece: [Stroke] = []
        var room = texels
        while let head = strokes.first, room > 0, piece.first.map({ $0.into == head.into }) ?? true {
            if head.texels <= room {
                piece.append(head)
                strokes.removeFirst()
                room -= head.texels
                continue
            }
            let rows = max(room / head.scissor.width, piece.isEmpty ? 1 : 0)
            guard rows > 0 else { break }
            guard rows < head.scissor.height else {
                piece.append(head)
                strokes.removeFirst()
                room -= head.texels
                continue
            }
            var band = head
            band.scissor.height = rows
            strokes[0].scissor.y += rows
            strokes[0].scissor.height -= rows
            piece.append(band)
            room -= band.texels
        }
        return piece
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
    /// Leading edge of a Fly To's sweep at the last frame, nil when none was under way.
    private var lastSweepFront: Double?
    /// During a Fly To, the new place as it will be once the sweep is over, painted in a cache of its own a few rows
    /// ahead of the sweep each frame. The frame pass blends it in where the land has turned, and when the sweep ends
    /// it becomes the ground. Repainting the moving band in the one cache instead costs most of the screen a frame.
    private var incoming: (color: MTLTexture, mask: MTLTexture)?
    /// The world texel row the new place's cache is painted up to, exclusive.
    private var incomingFilled: Int?
    /// The leg being flown to, so a second Fly To during the first starts over.
    private var sweepLeg: Int?
    /// Cloud-space position of the cloud texture's bottom-left corner when it was last painted.
    private var cloudCorner: SIMD2<Double>?
    private static let cloudMargin = 48
    private var paper: MTLTexture?
    private var paperDirty = true
    /// Kept for the power policy; clouds are already only repainted every few seconds.
    var halfRateClouds = false
    /// Paper grain and edge strength.
    var finish = SIMD4<Float>(1, 0.3, 0, 0)
    /// The pale dry-brush border round the painting, which can be turned off.
    var paperEdge = true {
        didSet { finish.y = paperEdge ? 0.3 : 0 }
    }
    /// Half the bird's wingspan, in points.
    var birdSize = 27.0
    /// Draw the bird into the frame, for stills and exports; live it has a layer of its own.
    var drawsBird = true
    /// How the ground cache is read; see `groundColorAt` in Composite.metal. 0, one bilinear tap, suits Retina.
    var groundFilter: Float = 0
    /// Ground texels painted by the last frame.
    private(set) var paintedTexels = 0
    /// GPU time of a frame here that paints next to nothing, to tell what painting costs.
    private var plainFrame: Double?
    /// Ground being painted in pieces of GPU work of their own ahead of the frames, which wait for it (see `catchUp`).
    private var chain: Chain?
    private struct Chain {
        var strokes: GroundStrokes
        let targets: [[MTLTexture]]
        let scenes: [SceneGPU]
        var inFlight = 0
        var failed = false
        /// Started over by `configure` or `invalidate`, which is no fault of the GPU's.
        var superseded = false
        let done: @MainActor (CatchUp) -> Void
        /// Pieces painted so far, and the longest GPU time one took, for the log.
        var pieces = 0
        var longest = 0.0
    }
    /// How painting the ground ahead of the frames ended.
    enum CatchUp {
        case painted
        /// Something started it over, as a new display size or a change to the view does.
        case superseded
        case failed
    }
    /// A second Fly To began during the first, whose half-turned land is settled by painting the ground afresh.
    private var settlesSweep = false
    /// Ground a frame must paint that is too much for one piece of GPU work goes in pieces committed ahead of the
    /// frame. The exporter waits for each, and learns nothing from them, so its pictures never vary.
    var waitsForPieces = false
    /// Why the last such piece failed, while waiting for them.
    private(set) var pieceError: Error?
    /// Such a piece failed afterwards, so the ground is to be painted afresh.
    var onGroundLost: @MainActor () -> Void = {}

    /// A frame finished, taking `milliseconds` of GPU time and having painted `texels`: teaches the budget what
    /// painting costs on this GPU.
    func finished(gpu milliseconds: Double, painted texels: Int) {
        guard milliseconds.isFinite, milliseconds > 0 else { return }
        if texels < 20_000 {
            plainFrame = plainFrame.map { $0 + (milliseconds - $0) * 0.1 } ?? milliseconds
        } else if let plainFrame {
            gpu.paintBudget.learn(milliseconds: max(milliseconds - plainFrame, 0), painted: texels)
        }
    }
    #if DEBUG
    /// Heavy work the last frame did, for the frame statistics.
    private(set) var events: [String] = []
    #endif

    init(gpu: GPU) {
        self.gpu = gpu
    }

    /// Sets the view in global desktop points, the pixels per point to draw, and the ground texels per point to paint,
    /// which is the pixels per point unless given.
    func configure(frame: CGRect, scale: Double, density: Double? = nil) {
        let density = density ?? scale
        guard frame != self.frame || scale != self.scale || density != self.density else { return }
        self.frame = frame
        self.scale = scale
        self.density = density
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
        // The new place's cache is the old size, so a Fly To under way paints it again at the new one.
        incoming = nil
        incomingFilled = nil
        sweepLeg = nil
        chain?.superseded = true
    }

    func invalidate() {
        valid = nil
        cloudCorner = nil
        paperDirty = true
        chain?.superseded = true
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

    /// The ground isn't all painted in the world's present light yet: a repaint wave is crossing it, or about to, or
    /// it is still to be painted at all.
    func isRepainting(for world: World) -> Bool {
        revision != world.revision || repaintRow != nil || valid == nil || chain != nil
    }

    /// The view's world bounds at `t`: its left and bottom edges and its top.
    private func bounds(world: World, at t: TimeInterval) -> (x0: Double, y0: Double, top: Double) {
        let mpp = World.metresPerPoint
        let camera = world.camera(at: t)
        return (Double(frame.minX) * mpp + camera.x, Double(frame.minY) * mpp + camera.y,
                Double(frame.maxY) * mpp + camera.y)
    }

    /// The first world texel column and row of the cache the view at `t` needs.
    private func needed(world: World, at t: TimeInterval) -> (x: Int, y: Int) {
        let texel = World.metresPerPoint / density
        let view = bounds(world: world, at: t)
        return (Int((view.x0 / texel).rounded(.down)) - Self.pad, Int((view.y0 / texel).rounded(.down)) - Self.pad)
    }

    /// Whether the frame at `t` has more ground to paint than it should take on itself: all of it, as when nothing is
    /// cached yet, after a jump, or as a Fly To ends without the new place's cache whole, or over a quarter of it.
    /// Frames wait for `catchUp` then. Anything less a frame paints itself, in pieces ahead of it if need be, so a slow
    /// GPU falling a little behind, while a catch-up ran say, never stops drawing.
    func needsCatchUp(world: World, at t: TimeInterval) -> Bool {
        guard chain == nil, let valid else { return true }
        let need = needed(world: world, at: t)
        let dx = abs(need.x - valid.x), dy = abs(need.y - valid.y)
        guard dx < cacheWidth, dy < cacheHeight else { return true }
        if lastSweepFront != nil, !incomingIsWhole {
            let view = bounds(world: world, at: t)
            if world.frame(bottom: view.y0, top: view.top, at: t).sweepFront == nil { return true }
        }
        let texels = dy * cacheWidth + dx * (cacheHeight - dy)
        return texels > max(gpu.groundCost.texelsPerPiece, cacheWidth * cacheHeight / 4)
    }

    var isCatchingUp: Bool { chain != nil }

    /// Paints the ground the frame at `t` needs in pieces of GPU work of their own, each sent as the one before
    /// finishes and sized from what it cost, two at most on the GPU at once, so none runs long on a slow GPU: macOS
    /// stops GPU work that does, and after enough of it takes no more from the app at all. Nothing is drawn from the
    /// cache until it is whole. Calls `done` with how it ended; unless it painted, the cache is painted afresh.
    func catchUp(world: World, at t: TimeInterval, done: @escaping @MainActor (CatchUp) -> Void) {
        guard chain == nil else { return }
        guard let work = prepareGround(world: world, at: t) else {
            done(.failed)
            return
        }
        // Frames learn what painting costs from what they paint themselves, and this isn't theirs.
        paintedTexels = 0
        chain = Chain(strokes: work.strokes, targets: work.targets, scenes: work.scenes, done: done)
        pump()
    }

    /// Sends pieces while fewer than two are on the GPU, and ends the chain once none are and none are left, or one
    /// failed.
    private func pump() {
        guard var chain else { return }
        while chain.inFlight < 2, !chain.failed, !chain.superseded, !chain.strokes.isEmpty {
            let piece = chain.strokes.take(texels: gpu.groundCost.texelsPerPiece)
            guard let into = piece.first?.into, let commands = gpu.commandBuffer() else {
                chain.failed = true
                break
            }
            let sent = gpu.cuts
            paint(piece, into: chain.targets[into], scene: chain.scenes[into], clearing: false, commandBuffer: commands)
            let texels = piece.reduce(0) { $0 + $1.texels }
            commands.addCompletedHandler { [weak self] buffer in
                let outcome = GPUOutcome(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.pieceFinished(outcome, texels: texels, sent: sent) }
                }
            }
            commands.commit()
            chain.inFlight += 1
        }
        self.chain = chain
        guard chain.inFlight == 0 else { return }
        self.chain = nil
        let end: CatchUp = chain.failed ? .failed : chain.superseded ? .superseded
            : chain.strokes.isEmpty ? .painted : .failed
        if end != .painted { valid = nil }
        gpu.saveCost()
        Log.render.info("Ground \(String(describing: end), privacy: .public) in \(chain.pieces) pieces, the longest \(String(format: "%.1f", chain.longest), privacy: .public) ms; \(self.gpu.groundCost.texelsPerPiece) texels a piece now")
        chain.done(end)
    }

    private func pieceFinished(_ outcome: GPUOutcome, texels: Int, sent: Int) {
        guard var chain else { return }
        chain.inFlight -= 1
        chain.pieces += 1
        chain.longest = max(chain.longest, outcome.milliseconds)
        if outcome.completed {
            gpu.learn(texels: texels, milliseconds: outcome.milliseconds)
        } else {
            chain.failed = true
            gpu.failed(outcome, doing: "painting the ground", sent: sent)
        }
        self.chain = chain
        pump()
    }

    /// Draws the world as it is now, for stills and exports.
    func encode(world: World, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        encode(world: world, at: world.time, into: target, commandBuffer: commandBuffer)
    }

    /// The ground a frame paints before it draws: the draws, the caches they paint (the ground's own, and during a Fly
    /// To the new place's), and the scene each is painted with.
    private struct Prepared {
        var worldFrame: World.Frame
        var full: Bool
        var x0: Double
        var y0: Double
        var top: Double
        var strokes: GroundStrokes
        var targets: [[MTLTexture]]
        var scenes: [SceneGPU]
    }

    /// Works out the ground the frame at `t` paints, and moves the cache's bookkeeping on as if it were painted.
    private func prepareGround(world: World, at t: TimeInterval) -> Prepared? {
        let mpp = World.metresPerPoint
        let texel = mpp / density
        let camera = world.camera(at: t)
        let x0 = Double(frame.minX) * mpp + camera.x
        let y0 = Double(frame.minY) * mpp + camera.y
        let top = Double(frame.maxY) * mpp + camera.y
        let worldFrame = world.frame(bottom: y0, top: top, at: t)
        let scene = worldFrame.scene
        lastScene = scene
        if worldFrame.sweepFront == nil, lastSweepFront != nil { finishSweep() }
        guard let color, let mask, clouds != nil else { return nil }

        // Work out which world texel rectangles need painting.
        let need = needed(world: world, at: t)
        var full = valid == nil
        // Anything else baked into the ground changing (the sun moving on, a new season) is repainted as a wave
        // from top to bottom, a budgeted number of rows a frame, so no single frame has to repaint the whole screen.
        if revision != world.revision {
            repaintRow = valid == nil ? nil : (valid!.y + cacheHeight)
            cloudCorner = nil
            incomingFilled = nil
        }
        var rects: [Rect] = []
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
        // Newly revealed ground can't wait; it still counts against the budget for what can.
        let revealed = rects
        gpu.paintBudget.spend(revealed.reduce(0) { $0 + $1.w * $1.h }, at: t)
        if !full, let wave = repaintRow {
            let row = min(wave, need.y + cacheHeight)
            let granted = gpu.paintBudget.take(max(cacheHeight / 12, 1) * cacheWidth, at: t)
            let low = max(row - max(granted / cacheWidth, 1), need.y)
            if low < row { rects.append((need.x, low, cacheWidth, row - low)) }
            repaintRow = low > need.y ? low : nil
        } else if full {
            repaintRow = nil
        }
        var incomingRects: [Rect] = []
        if let front = worldFrame.sweepFront {
            incomingRects = sweepRects(front: front, need: need, revealed: revealed, texel: texel,
                                       leg: worldFrame.legB.index, at: t)
        }
        valid = need
        if settlesSweep {
            // Painted afresh, in full, from the next frame on.
            valid = nil
            settlesSweep = false
        }
        revision = world.revision
        lastSweepFront = worldFrame.sweepFront
        paintedTexels = (rects + incomingRects).reduce(0) { $0 + $1.w * $1.h }
        #if DEBUG
        events = []
        if full { events.append("full") }
        if repaintRow != nil { events.append("wave") }
        if worldFrame.sweepFront != nil { events.append("sweep") }
        #endif

        var strokes = self.strokes(rects, into: 0, texel: texel, reference: worldFrame.reference)
        var targets = [[color, mask]]
        var scenes = [scene]
        if let incoming, !incomingRects.isEmpty {
            // The new place as it will be once the sweep is over.
            var settled = scene
            settled.morph.y = 0.001
            settled.morph.z = -1
            strokes += self.strokes(incomingRects, into: 1, texel: texel, reference: worldFrame.reference)
            targets.append([incoming.color, incoming.mask])
            scenes.append(settled)
        }
        return Prepared(worldFrame: worldFrame, full: full, x0: x0, y0: y0, top: top, strokes: GroundStrokes(strokes),
                        targets: targets, scenes: scenes)
    }

    /// Draws the world as it is at `t`, the moment this frame will be on screen.
    func encode(world: World, at t: TimeInterval, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let work = prepareGround(world: world, at: t), let color, let mask, let clouds else { return }
        let mpp = World.metresPerPoint
        let texel = mpp / density
        let worldFrame = work.worldFrame
        let (full, x0, y0, top) = (work.full, work.x0, work.y0, work.top)
        var scene = worldFrame.scene
        let pipelines = gpu.shaders.pipelines
        paintGround(work, commandBuffer: commandBuffer)

        // Clouds never change shape, they only drift, so they are painted at a quarter of the resolution
        // with a margin and slid along until the margin runs out.
        let metresPerPixel = mpp / scale
        let cloudPixel = metresPerPixel * 4
        let origin = SIMD2(Double(frame.minX), Double(frame.minY)) * mpp
        let viewCloud = world.cloudSpace(origin, at: t)
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
            #if DEBUG
            events.append("clouds")
            #endif
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
        let gust = world.gustSpace(origin, at: t)
        let bird = world.birdPose(at: t)
        let birdPoint = bird.position - SIMD2(Double(frame.minX), Double(frame.minY))
        let birdVisible = birdPoint.x > -90 && birdPoint.y > -90
            && birdPoint.x < Double(frame.width) + 90 && birdPoint.y < Double(frame.height) + 90
        var finish = self.finish
        finish.z = drawsBird ? 1 : 0
        finish.w = groundFilter
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
        if let (flock, sighting) = world.flock(at: t) {
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
            encoder.setFragmentTexture(incoming?.color ?? color, index: 5)
            encoder.setFragmentTexture(incoming?.mask ?? mask, index: 6)
            encoder.setFragmentSamplerState(gpu.wrap, index: 0)
            encoder.setFragmentSamplerState(gpu.clamp, index: 1)
            encoder.setRenderPipelineState(pipelines.view)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            let batches = animalBatches(frame: worldFrame, time: t, x0: x0, x1: x0 + Double(frame.width) * mpp,
                                        y0: y0, top: top)
            if !batches.isEmpty {
                encoder.setRenderPipelineState(pipelines.animals)
                encoder.setVertexBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 2)
                encoder.setVertexBytes(&params, length: MemoryLayout<CompositeGPU>.stride, index: 3)
                encoder.setVertexTexture(color, index: 0)
                encoder.setVertexTexture(incoming?.color ?? color, index: 1)
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
    private func animalBatches(frame: World.Frame, time: TimeInterval, x0: Double, x1: Double, y0: Double,
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
            let drift = World.herdDrift(time: time, seed: UInt32(region.gpu.info.y))
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

    typealias Rect = (x: Int, y: Int, w: Int, h: Int)

    /// The draws that paint world texel rectangles of the ground into one of the caches.
    private func strokes(_ rects: [Rect], into cache: Int, texel: Double, reference: Double) -> [GroundStrokes.Stroke] {
        rects.flatMap(pieces).map { piece in
            GroundStrokes.Stroke(
                params: GroundGPU(origin: SIMD4(Float(piece.tx), Float(piece.ty), Float(Double(piece.wx) * texel),
                                                Float(Double(piece.wy) * texel - reference)),
                                  texel: SIMD4(Float(texel), 0, 0, 0)),
                scissor: MTLScissorRect(x: piece.tx, y: piece.ty, width: piece.w, height: piece.h),
                into: cache)
        }
    }

    /// Paints a frame's ground: in the frame's own command buffer when it fits in one piece of GPU work, as it nearly
    /// always does, or else in pieces of their own committed ahead of the frame.
    private func paintGround(_ work: Prepared, commandBuffer: MTLCommandBuffer) {
        var strokes = work.strokes
        guard strokes.texels > gpu.groundCost.texelsPerPiece else {
            for (i, targets) in work.targets.enumerated() {
                paint(strokes.strokes.filter { $0.into == i }, into: targets, scene: work.scenes[i],
                      clearing: i == 0 && work.full, commandBuffer: commandBuffer)
            }
            return
        }
        // The frame's own GPU time leaves these out, so it mustn't count them as its painting.
        paintedTexels = 0
        while !strokes.isEmpty {
            let piece = strokes.take(texels: gpu.groundCost.texelsPerPiece)
            guard let into = piece.first?.into else { return }
            guard let commands = gpu.commandBuffer() else {
                // The rest isn't painted, so the next frame paints all of it again; an export stops here.
                valid = nil
                if waitsForPieces {
                    pieceError = NSError(domain: MTLCommandBufferErrorDomain,
                                         code: Int(MTLCommandBufferError.Code.internal.rawValue))
                }
                return
            }
            paint(piece, into: work.targets[into], scene: work.scenes[into], clearing: false, commandBuffer: commands)
            if waitsForPieces {
                commands.commit()
                commands.waitUntilCompleted()
                if let error = commands.error {
                    pieceError = error
                    return
                }
                continue
            }
            let texels = piece.reduce(0) { $0 + $1.texels }
            let sent = gpu.cuts
            commands.addCompletedHandler { [weak self] buffer in
                let outcome = GPUOutcome(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if outcome.completed {
                            self.gpu.learn(texels: texels, milliseconds: outcome.milliseconds)
                        } else {
                            self.gpu.failed(outcome, doing: "painting the ground", sent: sent)
                            self.invalidate()
                            self.onGroundLost()
                        }
                    }
                }
            }
            commands.commit()
        }
    }

    /// Paints ground into a cache.
    private func paint(_ strokes: [GroundStrokes.Stroke], into targets: [MTLTexture], scene: SceneGPU, clearing: Bool,
                       commandBuffer: MTLCommandBuffer) {
        guard !strokes.isEmpty else { return }
        var scene = scene
        let pass = MTLRenderPassDescriptor()
        for (i, texture) in targets.enumerated() {
            pass.colorAttachments[i].texture = texture
            pass.colorAttachments[i].loadAction = clearing ? .dontCare : .load
            pass.colorAttachments[i].storeAction = .store
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Ground"
        encoder.setRenderPipelineState(gpu.shaders.pipelines.ground)
        encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
        for stroke in strokes {
            var params = stroke.params
            encoder.setScissorRect(stroke.scissor)
            encoder.setFragmentBytes(&params, length: MemoryLayout<GroundGPU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    /// What the new place's cache needs this frame during a Fly To: the ground's newly revealed strips for the rows it
    /// already holds, then rows upward from where it got to, always as far as the sweep's front, where the land starts
    /// to turn, and further as the budget allows, so it is ready before the front gets there.
    private func sweepRects(front: Double, need: (x: Int, y: Int), revealed: [Rect], texel: Double, leg: Int,
                            at t: TimeInterval) -> [Rect] {
        if sweepLeg != leg {
            // A Fly To during another: settle what the first had turned so far by repainting the ground, then begin
            // the new place afresh.
            if sweepLeg != nil { settlesSweep = true }
            sweepLeg = leg
            incomingFilled = nil
            if incoming == nil || incoming?.color.width != cacheWidth || incoming?.color.height != cacheHeight,
               let color = makeTexture(width: cacheWidth, height: cacheHeight, label: "Ground flown to"),
               let mask = makeTexture(width: cacheWidth, height: cacheHeight, label: "Ground flown to at night",
                                      format: ShaderLibrary.nightFormat) {
                incoming = (color, mask)
            }
        }
        guard incoming != nil else { return [] }
        let filled = max(incomingFilled ?? need.y, need.y)
        var out: [Rect] = []
        for rect in revealed {
            let low = max(rect.y, need.y), high = min(rect.y + rect.h, filled)
            if high > low { out.append((rect.x, low, rect.w, high - low)) }
        }
        let topRow = need.y + cacheHeight
        // Two rows past the front, for the filters' taps.
        let frontRow = min(Int((front / texel).rounded(.up)) + 2, topRow)
        let must = max(frontRow - filled, 0)
        gpu.paintBudget.spend(must * cacheWidth, at: t)
        let extra = gpu.paintBudget.take(max(topRow - filled - must, 0) * cacheWidth, at: t) / cacheWidth
        let reach = min(filled + must + extra, topRow)
        if reach > filled { out.append((need.x, filled, cacheWidth, reach - filled)) }
        incomingFilled = reach
        return out
    }

    /// A Fly To has finished: the new place's cache, painted all the way up, becomes the ground. Were it somehow not,
    /// the ground is repainted in full once.
    private func finishSweep() {
        defer {
            incoming = nil
            incomingFilled = nil
            sweepLeg = nil
        }
        guard incomingIsWhole, let incoming else {
            self.valid = nil
            return
        }
        color = incoming.color
        mask = incoming.mask
    }

    /// The new place's cache is painted all the way up, at the size of the ground's.
    private var incomingIsWhole: Bool {
        guard let incoming, let valid, let filled = incomingFilled else { return false }
        return filled >= valid.y + cacheHeight && incoming.color.width == cacheWidth
            && incoming.color.height == cacheHeight
    }

    /// The shortest offset between two points of the repeating cloud space.
    private static func wrapped(_ d: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((d.x + 8192).positiveRemainder(16384) - 8192, (d.y + 8192).positiveRemainder(16384) - 8192)
    }

    /// The last landscape frame's scene, whose light the bird's own layer borrows.
    private var lastScene: SceneGPU?

    /// Paints the bird alone, as it is at `t`, into the small layer that follows it, `size` points square around
    /// its centre.
    func encodeBird(world: World, at t: TimeInterval, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                    size: Double, scale: Double) {
        let bird = world.birdPose(at: t)
        let centre = Float(size * scale * 0.5)
        var params = CompositeGPU(
            view: SIMD4(Float(target.width), Float(target.height), Float(World.metresPerPoint / scale), 0),
            world: .zero, cache: .zero,
            bird: SIMD4(centre, centre, Float(bird.heading - .pi / 2), Float(bird.bank)),
            wings: SIMD4(Float(bird.wings), 14, Float(birdSize * scale), 1),
            finish: .zero, clouds: .zero, flock: .zero, flockShape: .zero, flockLook: .zero)
        var scene = lastScene ?? world.frame(bottom: world.camera.y, top: world.camera.y + 1).scene
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
