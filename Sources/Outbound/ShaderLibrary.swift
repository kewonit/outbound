import Foundation
import Metal

/// Compiles the shaders from source at launch. In debug builds, pointing OUTBOUND_SHADERS at the
/// Shaders folder recompiles them whenever a file there is saved.
@MainActor
final class ShaderLibrary {
    struct Pipelines {
        let ground: MTLRenderPipelineState
        let clouds: MTLRenderPipelineState
        let paper: MTLRenderPipelineState
        /// The three draws of the frame pass: ground, instanced animals, sky.
        let view: MTLRenderPipelineState
        let animals: MTLRenderPipelineState
        let sky: MTLRenderPipelineState
        let bird: MTLRenderPipelineState
    }

    static let files = ["Common.metal", "Ground.metal", "Clouds.metal", "Composite.metal"]
    static let cacheFormat = MTLPixelFormat.rgba8Unorm
    static let nightFormat = MTLPixelFormat.rg8Unorm
    static let viewFormat = MTLPixelFormat.bgra8Unorm
    static let paperFormat = MTLPixelFormat.rg8Unorm
    /// Night light, which only ever lives in tile memory, so its size costs nothing.
    static let lightFormat = MTLPixelFormat.rgba8Unorm

    let device: MTLDevice
    private(set) var pipelines: Pipelines
    var onReload: () -> Void = {}
    private var watcher: DispatchSourceFileSystemObject?

    init(device: MTLDevice) throws {
        self.device = device
        pipelines = try Self.build(device: device, source: try Self.source())
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

    private static func build(device: MTLDevice, source: String) throws -> Pipelines {
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library = try device.makeLibrary(source: source, options: options)

        func pipeline(_ fragment: String, vertex: String = "fullscreen", formats: [MTLPixelFormat],
                      writes: Int? = nil) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            for (i, format) in formats.enumerated() {
                descriptor.colorAttachments[i].pixelFormat = format
                if let writes, i >= writes { descriptor.colorAttachments[i].writeMask = [] }
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let frame = [viewFormat, lightFormat]
        return Pipelines(ground: try pipeline("ground", formats: [cacheFormat, nightFormat]),
                         clouds: try pipeline("clouds", formats: [cacheFormat]),
                         paper: try pipeline("paper", formats: [paperFormat]),
                         view: try pipeline("viewGround", formats: frame),
                         animals: try pipeline("animalFragment", vertex: "animalVertex", formats: frame, writes: 1),
                         sky: try pipeline("sky", formats: frame, writes: 1),
                         bird: try pipeline("birdSprite", formats: [viewFormat]))
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
            pipelines = try Self.build(device: device, source: try Self.source())
            Log.render.info("Shaders reloaded")
            onReload()
        } catch {
            Log.render.error("Shader reload failed: \(String(describing: error), privacy: .public)")
        }
    }
}
