import Foundation
import Metal

/// Compiles the shaders from source at launch. In debug builds, pointing OUTBOUND_SHADERS at the
/// Shaders folder recompiles them whenever a file there is saved.
@MainActor
final class ShaderLibrary {
    struct Pipelines {
        let ground: MTLRenderPipelineState
        let clouds: MTLRenderPipelineState
        let bank: MTLRenderPipelineState
        let gusts: MTLRenderPipelineState
        let paper: MTLRenderPipelineState
        /// The three draws of the frame pass: ground, instanced animals, sky.
        let view: MTLRenderPipelineState
        let animals: MTLRenderPipelineState
        let sky: MTLRenderPipelineState
        let bird: MTLRenderPipelineState
        /// Leaner copies of the frame's ground and sky draws, each left without parts most frames have no use for (see
        /// Composite.metal). A copy still compiling is nil, and the whole shader draws the same picture meanwhile.
        var lean = Lean()
    }

    struct Lean {
        /// The ground by day and after dark, with no train passing and no Fly To under way.
        var viewByDay: MTLRenderPipelineState?
        var viewAfterDark: MTLRenderPipelineState?
        /// The sky with no bird or flock in it, without the band of cloud between two places and with it.
        var skyPlain: MTLRenderPipelineState?
        var skyBand: MTLRenderPipelineState?
        /// The same two over rectangles, for all of a frame but the bird's corner of it, and the whole sky for that.
        var skyAround: MTLRenderPipelineState?
        var skyBandAround: MTLRenderPipelineState?
        var skyBird: MTLRenderPipelineState?
    }

    /// Which parts a copy of a frame shader has; the numbers are the shader's own for them.
    private enum Part: Int, CaseIterable {
        case dark, train, sweep, bird, flock, band
    }

    static let files = ["Common.metal", "Ground.metal", "Clouds.metal", "Composite.metal"]
    static let cacheFormat = MTLPixelFormat.rgba8Unorm
    static let nightFormat = MTLPixelFormat.rg8Unorm
    static let viewFormat = MTLPixelFormat.bgra8Unorm
    static let paperFormat = MTLPixelFormat.rg8Unorm
    /// Half floats, as the cats' paws are cut out of their field by a steep smoothstep.
    static let gustFormat = MTLPixelFormat.rg16Float
    /// Night light, which only ever lives in tile memory, so its size costs nothing.
    static let lightFormat = MTLPixelFormat.rgba8Unorm

    let device: MTLDevice
    private(set) var pipelines: Pipelines
    var onReload: () -> Void = {}
    private var watcher: DispatchSourceFileSystemObject?
    /// Counts builds, so a lean copy that finishes compiling after the shaders were reloaded is never used.
    private var builds = 0

    /// Compiles the shaders. The lean copies of the frame's shaders compile afterwards on their own, as nothing waits
    /// for them, unless `leanNow`, as where every picture must come out the same whenever it is made.
    init(device: MTLDevice, leanNow: Bool = false) throws {
        self.device = device
        let library = try Self.library(device: device, source: try Self.source())
        pipelines = try Self.build(device: device, library: library)
        try compileLean(from: library, now: leanNow)
        #if DEBUG
        watch()
        #endif
    }

    private static var directory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OUTBOUND_SHADERS"] { return URL(filePath: path) }
        #endif
        return Bundle.module.url(forResource: "Shaders", withExtension: nil)!
    }

    private static func source() throws -> String {
        // Concatenated rather than #included: a library built from a string has no folder to search.
        try files.map { try String(contentsOf: directory.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    private static func library(device: MTLDevice, source: String) throws -> MTLLibrary {
        let options = MTLCompileOptions()
        if #available(macOS 15, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        #if DEBUG
        // OUTBOUND_SLOW_GPU=n paints the ground n times over, to see how a GPU n times slower copes.
        if let slow = ProcessInfo.processInfo.environment["OUTBOUND_SLOW_GPU"].flatMap(Int.init), slow > 1 {
            options.preprocessorMacros = ["OUTBOUND_SLOW_GPU": NSNumber(value: slow)]
            Log.render.info("Painting the ground \(slow) times over")
        }
        #endif
        return try device.makeLibrary(source: source, options: options)
    }

    /// What a pipeline is made from. With `parts`, the fragment shader is a copy that has only those.
    private static func descriptor(_ fragment: String, vertex: String = "fullscreen", formats: [MTLPixelFormat],
                                   writes: Int? = nil, parts: Set<Part>? = nil, label: String? = nil,
                                   in library: MTLLibrary) throws -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label ?? fragment
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        if let parts {
            let values = MTLFunctionConstantValues()
            for part in Part.allCases {
                var has = parts.contains(part)
                values.setConstantValue(&has, type: .bool, index: part.rawValue)
            }
            descriptor.fragmentFunction = try library.makeFunction(name: fragment, constantValues: values)
        } else {
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
        }
        for (i, format) in formats.enumerated() {
            descriptor.colorAttachments[i].pixelFormat = format
            if let writes, i >= writes { descriptor.colorAttachments[i].writeMask = [] }
        }
        return descriptor
    }

    private static let frameFormats = [viewFormat, lightFormat]

    private static func build(device: MTLDevice, library: MTLLibrary) throws -> Pipelines {
        func pipeline(_ fragment: String, vertex: String = "fullscreen", formats: [MTLPixelFormat],
                      writes: Int? = nil, parts: Set<Part>? = nil) throws -> MTLRenderPipelineState {
            try device.makeRenderPipelineState(descriptor: descriptor(fragment, vertex: vertex, formats: formats,
                                                                      writes: writes, parts: parts, in: library))
        }
        // A shader that comes in copies has to be told its parts even to have them all.
        let whole = Set(Part.allCases)
        let frame = frameFormats
        return Pipelines(ground: try pipeline("ground", formats: [cacheFormat, nightFormat]),
                         clouds: try pipeline("clouds", formats: [cacheFormat]),
                         bank: try pipeline("bank", formats: [cacheFormat]),
                         gusts: try pipeline("gusts", formats: [gustFormat]),
                         paper: try pipeline("paper", formats: [paperFormat]),
                         view: try pipeline("viewGround", formats: frame, parts: whole),
                         animals: try pipeline("animalFragment", vertex: "animalVertex", formats: frame, writes: 1),
                         sky: try pipeline("sky", formats: frame, writes: 1, parts: whole),
                         bird: try pipeline("birdSprite", formats: [viewFormat]))
    }

    /// Compiles the lean copies of the frame's shaders, now or each on its own with nothing waiting for it.
    private func compileLean(from library: MTLLibrary, now: Bool) throws {
        builds += 1
        let build = builds
        let frame = Self.frameFormats
        let copies: [(WritableKeyPath<Lean, MTLRenderPipelineState?>, MTLRenderPipelineDescriptor)] = [
            (\.viewByDay, try Self.descriptor("viewGround", formats: frame, parts: [], label: "viewGround by day",
                                              in: library)),
            (\.viewAfterDark, try Self.descriptor("viewGround", formats: frame, parts: [.dark],
                                                  label: "viewGround after dark", in: library)),
            (\.skyPlain, try Self.descriptor("sky", formats: frame, writes: 1, parts: [], label: "sky, plain",
                                             in: library)),
            (\.skyBand, try Self.descriptor("sky", formats: frame, writes: 1, parts: [.band], label: "sky with a band",
                                            in: library)),
            (\.skyAround, try Self.descriptor("sky", vertex: "tiles", formats: frame, writes: 1, parts: [],
                                              label: "sky round the bird", in: library)),
            (\.skyBandAround, try Self.descriptor("sky", vertex: "tiles", formats: frame, writes: 1, parts: [.band],
                                                  label: "sky with a band round the bird", in: library)),
            (\.skyBird, try Self.descriptor("sky", vertex: "tiles", formats: frame, writes: 1,
                                            parts: Set(Part.allCases), label: "sky over the bird", in: library))
        ]
        for (place, descriptor) in copies {
            if now {
                pipelines.lean[keyPath: place] = try device.makeRenderPipelineState(descriptor: descriptor)
                continue
            }
            // The key path is only ever used on the main thread.
            nonisolated(unsafe) let place = place
            device.makeRenderPipelineState(descriptor: descriptor) { [weak self] state, error in
                let made = state.map(Compiled.init)
                let failure = error.map { String(describing: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.builds == build else { return }
                        if let made {
                            self.pipelines.lean[keyPath: place] = made.state
                        } else {
                            Log.render.error("A lean shader didn't compile: \(failure ?? "?", privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    /// A pipeline on its way from the thread Metal compiled it on to the main one.
    private struct Compiled: @unchecked Sendable {
        let state: MTLRenderPipelineState
    }

    private func watch() {
        guard ProcessInfo.processInfo.environment["OUTBOUND_SHADERS"] != nil else { return }
        let descriptor = open(Self.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        Log.render.info("Watching shaders in \(Self.directory.path, privacy: .public)")
    }

    private func reload() {
        do {
            let library = try Self.library(device: device, source: try Self.source())
            pipelines = try Self.build(device: device, library: library)
            try compileLean(from: library, now: true)
            Log.render.info("Shaders reloaded")
            onReload()
        } catch {
            Log.render.error("Shader reload failed: \(String(describing: error), privacy: .public)")
        }
    }
}
