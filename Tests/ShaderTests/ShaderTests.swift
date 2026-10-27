import Foundation
import Metal
import Testing
@testable import Outbound
@testable import OutboundCore

/// The wallpaper's shaders, run on the GPU.
///
/// The kernels in Probes.metal call shader functions over a grid of inputs. The promise kernels check what each
/// function guarantees on the GPU itself; these tests run them, look at what the probes return across a whole
/// grid, and render whole passes. Everything runs on two builds: the real shaders, and the frozen copy in
/// Shipped/ of the shaders as v1.0 had them. Where the two disagree, something about the look has changed. If that
/// was meant, refresh Shipped/ from Sources/Outbound/Shaders, keeping the note at the top.
@MainActor
@Suite(.serialized)
struct ShaderTests {
    let bench = Bench.shared

    @Test func bothBuildsHaveEveryEntryPoint() throws {
        let used = ["fullscreen", "ground", "clouds", "paper", "viewGround", "animalVertex", "animalFragment", "sky",
                    "birdSprite"]
        for library in [bench.current, bench.shipped] {
            #expect(Set(used).isSubset(of: library.functionNames), "\(library.label ?? "")")
        }
        // Newer than the shipped copy: the dissolve on coming back to a display.
        #expect(bench.current.functionNames.contains("parting"))
    }

    @Test func structsAreLaidOutTheSameAsInSwift() throws {
        let expected: [(String, Int)] = [
            ("Biome", MemoryLayout<BiomeGPU>.stride),
            ("Leg", MemoryLayout<LegGPU>.stride),
            ("Train", MemoryLayout<TrainGPU>.stride),
            ("Scene", MemoryLayout<SceneGPU>.stride),
            ("GroundParams", MemoryLayout<GroundGPU>.stride),
            ("CloudParams", MemoryLayout<CloudsGPU>.stride),
            ("CompositeParams", MemoryLayout<CompositeGPU>.stride),
            ("AnimalParams", MemoryLayout<AnimalsGPU>.stride),
            ("Biome.a", MemoryLayout<BiomeGPU>.offset(of: \.a)!),
            ("Biome.lamp", MemoryLayout<BiomeGPU>.offset(of: \.lamp)!),
            ("Biome.roof0", MemoryLayout<BiomeGPU>.offset(of: \.roof0)!),
            ("Biome.i", MemoryLayout<BiomeGPU>.offset(of: \.i)!),
            ("Biome.k", MemoryLayout<BiomeGPU>.offset(of: \.k)!),
            ("Biome.blossomLight", MemoryLayout<BiomeGPU>.offset(of: \.blossomLight)!),
            ("Biome.l", MemoryLayout<BiomeGPU>.offset(of: \.l)!),
            ("Leg.info", MemoryLayout<LegGPU>.offset(of: \.info)!),
            ("Leg.railShape", MemoryLayout<LegGPU>.offset(of: \.railShape)!),
            ("Train.run", MemoryLayout<TrainGPU>.offset(of: \.run)!),
            ("Train.locomotive", MemoryLayout<TrainGPU>.offset(of: \.locomotive)!),
            ("Scene.time", MemoryLayout<SceneGPU>.offset(of: \.time)!),
            ("Scene.clock", MemoryLayout<SceneGPU>.offset(of: \.clock)!),
            ("Scene.traffic", MemoryLayout<SceneGPU>.offset(of: \.traffic)!),
            ("Scene.train", MemoryLayout<SceneGPU>.offset(of: \.train)!),
            ("Scene.legA", MemoryLayout<SceneGPU>.offset(of: \.legA)!),
            ("Scene.legB", MemoryLayout<SceneGPU>.offset(of: \.legB)!),
            ("CloudParams.view", MemoryLayout<CloudsGPU>.offset(of: \.view)!),
            ("CompositeParams.finish", MemoryLayout<CompositeGPU>.offset(of: \.finish)!),
            ("CompositeParams.flockLook", MemoryLayout<CompositeGPU>.offset(of: \.flockLook)!),
            ("AnimalParams.drift", MemoryLayout<AnimalsGPU>.offset(of: \.drift)!),
        ]
        for library in [bench.current, bench.shipped] {
            let measured = try bench.layouts(in: library, count: expected.count)
            for ((name, swift), metal) in zip(expected, measured) {
                #expect(Int(metal) == swift, "\(name) in \(library.label ?? ""): Metal \(metal), Swift \(swift)")
            }
        }
    }

    // MARK: - What the functions promise

    @Test(arguments: Place.all.map(\.id))
    func shadersKeepTheirPromises(_ id: String) throws {
        let scene = try #require(try bench.scenes().first { $0.place == id })
        for library in [bench.current, bench.shipped] {
            let promises = library.functionNames.filter { $0.hasPrefix("promise") }.sorted()
            #expect(promises.count >= 12)
            for promise in promises {
                let broken = try bench.probe(promise, scene: scene.gpu, in: library)
                for part in 0..<4 {
                    let worst = Self.largest(broken.map { $0[part] })
                    #expect(worst == 0, "\(promise), part \(part + 1), over \(id) in \(library.label ?? ""): \(worst)")
                }
            }
        }
    }

    @Test func hashesSpreadEvenly() throws {
        let hashes = try bench.probe("probeHash")
        let values = hashes.flatMap { [$0.x, $0.z, $0.w] }
        #expect(abs(values.reduce(0, +) / Float(values.count) - 0.5) < 0.02)
        #expect(Set(hashes.map(\.x)).count > hashes.count * 99 / 100, "neighbouring cells hash apart")
    }

    @Test func housesLightUpAtDuskAndMostGoOutBeforeDawn() throws {
        let lit = try bench.probe("probeHouseLights")
        func share(_ hour: KeyPath<SIMD4<Float>, Float>) -> Float {
            Float(lit.filter { $0[keyPath: hour] > 0.5 }.count) / Float(lit.count)
        }
        #expect(share(\.x) == 0, "lit at noon")
        #expect(share(\.y) > 0.99, "lit at nine")
        #expect(share(\.z) > 0.1 && share(\.z) < share(\.y), "lit at half past eleven")
        #expect(share(\.w) > 0 && share(\.w) < 0.15, "lit at three")
    }

    @Test func theGullBanksAndCloudsBreak() throws {
        let gull = try bench.probe("probeBird")
        #expect(gull.contains { abs($0.z - $0.w) > 1e-3 }, "banking should shorten one wing")
        let clouds = try bench.probe("probeClouds")
        #expect(clouds.contains { $0.x > 0.5 } && clouds.contains { $0.x == 0 }, "cloud and clear sky both")
    }

    @Test(arguments: Place.all.map(\.id))
    func everyPlacePaintsItsGround(_ id: String) throws {
        let scene = try #require(try bench.scenes().first { $0.place == id })
        let land = try bench.probe("probeLandColour", scene: scene.gpu)
        #expect(land.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w >= 0 && $0.w <= 1 })
        let ground = try bench.renderGround(scene, in: bench.current)
        let colours = Set(stride(from: 0, to: ground.color.count, by: 4).map {
            UInt32(ground.color[$0]) << 16 | UInt32(ground.color[$0 + 1]) << 8 | UInt32(ground.color[$0 + 2])
        })
        #expect(colours.count > 50, "\(id) paints \(colours.count) colours")
    }

    // MARK: - Against v1.0

    @Test(arguments: Place.all.map(\.id))
    func probesMatchWhatShipped(_ id: String) throws {
        let scene = try #require(try bench.scenes().first { $0.place == id })
        let probes = bench.current.functionNames.filter { $0.hasPrefix("probe") }.sorted()
        #expect(probes.count > 15)
        for probe in probes {
            let now = try bench.probe(probe, scene: scene.gpu, in: bench.current)
            let then = try bench.probe(probe, scene: scene.gpu, in: bench.shipped)
            let worst = zip(now, then).map { Self.difference($0, $1) }.max() ?? 0
            #expect(worst <= 1e-4, "\(probe) over \(id) is \(worst) away from v1.0")
        }
    }

    @Test(arguments: Place.all.map(\.id))
    func groundMatchesWhatShipped(_ id: String) throws {
        let scene = try #require(try bench.scenes().first { $0.place == id })
        let now = try bench.renderGround(scene, in: bench.current)
        let then = try bench.renderGround(scene, in: bench.shipped)
        #expect(Self.worst(now.color, then.color) <= 1, "ground colour over \(id)")
        #expect(Self.worst(now.night, then.night) <= 1, "night light over \(id)")
    }

    @Test(arguments: [0.2, 0.55, 0.9])
    func cloudsMatchWhatShipped(_ cover: Float) throws {
        let now = try bench.renderClouds(cover: cover, in: bench.current)
        let then = try bench.renderClouds(cover: cover, in: bench.shipped)
        #expect(Self.worst(now, then) <= 1)
        #expect(now.contains { $0 > 0 }, "some cloud at cover \(cover)")
    }

    @Test func paperMatchesWhatShipped() throws {
        let now = try bench.renderPaper(in: bench.current)
        let then = try bench.renderPaper(in: bench.shipped)
        #expect(Self.worst(now, then) <= 1)
    }

    // MARK: - Helpers

    /// The largest magnitude among `values`; a NaN counts as infinitely large.
    static func largest(_ values: [Float]) -> Float {
        values.map { $0.isNaN ? .infinity : abs($0) }.max() ?? 0
    }

    /// The largest difference between two probe answers, counting matching infinities and NaNs as equal.
    static func difference(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        (0..<4).map { i in
            let x = a[i], y = b[i]
            if x == y || (x.isNaN && y.isNaN) { return 0 }
            return abs(x - y) / max(1, abs(x), abs(y))
        }.max()!
    }

    /// The largest difference between two images' bytes.
    static func worst(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}

/// The GPU, both builds of the shaders, and a scene over each place, made once for all the tests.
@MainActor
final class Bench {
    static let shared = try! Bench()

    struct Scene {
        let place: String
        var gpu: SceneGPU
        /// World y of the view's bottom edge, relative to the scene's reference.
        let bottom: Float
    }

    static let side = 64
    /// The app's own Metal objects, for its noise lattice and samplers.
    let gpu: GPU
    let device: MTLDevice
    let queue: MTLCommandQueue
    /// The shaders in Sources/Outbound/Shaders.
    let current: MTLLibrary
    /// The shaders as they shipped in v1.0.
    let shipped: MTLLibrary
    private var made: [Scene]?

    init() throws {
        gpu = try GPU()
        device = gpu.device
        queue = gpu.queue
        let here = URL(filePath: #filePath).deletingLastPathComponent()
        let probes = try String(contentsOf: here.appending(path: "Probes.metal"), encoding: .utf8)
        let shaders = here.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Outbound/Shaders")
        current = try Self.library(from: shaders, probes: probes, device: device)
        current.label = "current shaders"
        shipped = try Self.library(from: here.appending(path: "Shipped"), probes: probes, device: device)
        shipped.label = "v1.0 shaders"
    }

    /// Built as the app builds its library: the files joined in order, with fast math.
    private static func library(from folder: URL, probes: String, device: MTLDevice) throws -> MTLLibrary {
        let source = try ShaderLibrary.files
            .map { try String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")
        let options = MTLCompileOptions()
        if #available(macOS 15, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        return try device.makeLibrary(source: source + "\n" + probes, options: options)
    }

    /// A World over each place in its best season, flown a little way in, as the website's renders are, and on
    /// until a train passes where the place has a railway.
    func scenes() throws -> [Scene] {
        if let made { return made }
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let noon = Date(timeIntervalSince1970: 1_782_907_200)
        made = Place.all.map { place in
            let world = World(place: place, time: 0, date: noon, light: .alwaysDay)
            world.pointer = { nil }
            world.isDesktop = { _ in false }
            world.now = { noon }
            world.home = frame
            world.desktop = frame
            world.centreRiver(on: frame)
            world.journey.followsCalendar = false
            world.journey.refreshSeasons(date: noon)
            var time = 120.0
            world.advance(to: time)
            while place.railway != nil, !world.trainPassing, time < 7200 {
                time += 2
                world.advance(to: time)
            }
            let bottom = world.camera.y
            let view = world.frame(bottom: bottom, top: bottom + Double(frame.height) * World.metresPerPoint)
            return Scene(place: place.id, gpu: view.scene, bottom: Float(bottom - view.reference))
        }
        return made!
    }

    /// Three views as the frame pass gets them on a 1512 by 982 display, one for each kind of flock: a skein, a
    /// loose group and birds circling.
    static let views: [CompositeGPU] = (0..<3).map { formation in
        CompositeGPU(view: SIMD4(1512, 982, 0.45, 1), world: SIMD4(-340, 120, 0, 0), cache: SIMD4(17, 33, 2048, 1536),
                     bird: SIMD4(700, 500, 0.6, 0.2), wings: SIMD4(0.8, 60, 30, 1), finish: SIMD4(1, 1, 0, 0),
                     clouds: SIMD4(120, 80, 8, 0), flock: SIMD4(756, 491, 0.9, 1),
                     flockShape: SIMD4(Float(formation), 7, 9, 0.5), flockLook: SIMD4(0.92, 0.93, 0.95, 12))
    }

    func probe(_ name: String, scene: SceneGPU? = nil, in library: MTLLibrary? = nil) throws -> [SIMD4<Float>] {
        let count = Self.side * Self.side
        var scene = try scene ?? scenes()[0].gpu
        var views = Self.views
        let output = try #require(device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride))
        try compute(name, in: library ?? current, threads: count) { encoder in
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&scene, length: MemoryLayout<SceneGPU>.stride, index: 1)
            encoder.setBytes(&views, length: MemoryLayout<CompositeGPU>.stride * views.count, index: 2)
            encoder.setTexture(gpu.noise, index: 0)
            encoder.setSamplerState(gpu.wrap, index: 0)
        }
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self),
                                         count: count))
    }

    func layouts(in library: MTLLibrary, count: Int) throws -> [UInt32] {
        let output = try #require(device.makeBuffer(length: 64 * MemoryLayout<UInt32>.stride))
        try compute("layouts", in: library, threads: 1) { $0.setBuffer(output, offset: 0, index: 0) }
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt32.self), count: count))
    }

    private func compute(_ name: String, in library: MTLLibrary, threads: Int,
                         bind: (MTLComputeCommandEncoder) -> Void) throws {
        let function = try #require(library.makeFunction(name: name), "\(name) in \(library.label ?? "")")
        let pipeline = try device.makeComputePipelineState(function: function)
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        bind(encoder)
        encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, threads), height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    // MARK: - Whole passes

    /// A square of ground 256 texels across, a point to a texel, around the river at the bottom of the view.
    func renderGround(_ scene: Scene, in library: MTLLibrary) throws -> (color: [UInt8], night: [UInt8]) {
        let texel = Float(World.metresPerPoint)
        var params = GroundGPU(origin: SIMD4(0, 0, scene.gpu.road.x - 128 * texel, scene.bottom),
                               texel: SIMD4(texel, 0, 0, 0))
        var gpu = scene.gpu
        let images = try render("ground", in: library, formats: [ShaderLibrary.cacheFormat, ShaderLibrary.nightFormat]) {
            $0.setFragmentBytes(&params, length: MemoryLayout<GroundGPU>.stride, index: 0)
            $0.setFragmentBytes(&gpu, length: MemoryLayout<SceneGPU>.stride, index: 1)
        }
        return (images[0], images[1])
    }

    func renderClouds(cover: Float, in library: MTLLibrary) throws -> [UInt8] {
        var params = CloudsGPU(origin: SIMD4(900, -400, 8, cover), offsets: SIMD4(6, 4, -30, -20),
                               view: SIMD4(256, 0, 0, 0))
        return try render("clouds", in: library, formats: [ShaderLibrary.cacheFormat]) {
            $0.setFragmentBytes(&params, length: MemoryLayout<CloudsGPU>.stride, index: 0)
        }[0]
    }

    func renderPaper(in library: MTLLibrary) throws -> [UInt8] {
        var params = SIMD4<Float>(256, 256, 1, 0)
        return try render("paper", in: library, formats: [ShaderLibrary.paperFormat]) {
            $0.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }[0]
    }

    /// Draws one fragment over a 256 by 256 target per format and reads every target back.
    private func render(_ fragment: String, in library: MTLLibrary, formats: [MTLPixelFormat],
                        bind: (MTLRenderCommandEncoder) -> Void) throws -> [[UInt8]] {
        let size = 256
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let pass = MTLRenderPassDescriptor()
        var targets: [MTLTexture] = []
        for (i, format) in formats.enumerated() {
            descriptor.colorAttachments[i].pixelFormat = format
            let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size,
                                                                   mipmapped: false)
            texture.usage = .renderTarget
            texture.storageMode = .shared
            let target = try #require(device.makeTexture(descriptor: texture))
            pass.colorAttachments[i].texture = target
            pass.colorAttachments[i].loadAction = .clear
            pass.colorAttachments[i].storeAction = .store
            targets.append(target)
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        bind(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return zip(targets, formats).map { target, format in
            let bytes = format == .rg8Unorm ? 2 : 4
            var pixels = [UInt8](repeating: 0, count: size * size * bytes)
            target.getBytes(&pixels, bytesPerRow: size * bytes, from: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0)
            return pixels
        }
    }
}
