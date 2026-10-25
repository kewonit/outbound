import AppKit
import Metal
import OutboundCore
import UniformTypeIdentifiers

/// Renders frames to files without opening any windows, for checking the painting and for making
/// videos of it:
///
///     Outbound --render out.png [--place punjab] [--date 2026-04-20] [--hour 16.5] [--time 20]
///                               [--size 1512x982] [--scale 2]
///
/// Without --hour the light is always fair daytime; with it the sun stands where it would at that hour.
@MainActor
enum Exporter {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--render")
    }

    static func run(_ arguments: [String]) -> Int32 {
        var options: [String: String] = [:]
        var i = 1
        while i < arguments.count {
            let key = arguments[i]
            if key.hasPrefix("--"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                options[String(key.dropFirst(2))] = arguments[i + 1]
                i += 2
            } else {
                options[String(key.dropFirst(2))] = ""
                i += 1
            }
        }
        do {
            try render(options)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func render(_ options: [String: String]) throws {
        guard let output = options["render"], !output.isEmpty else { throw Failure(description: "--render needs a path") }
        let place = try Place.named(options["place"] ?? "punjab")
            ?? { throw Failure(description: "Unknown place. Try: \(Place.all.map(\.id).joined(separator: ", "))") }()
        var date = Date.now
        if let text = options["date"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            guard let parsed = formatter.date(from: text) else { throw Failure(description: "Dates look like 2026-04-20") }
            date = parsed.addingTimeInterval(12 * 3600)
        }
        let size = (options["size"] ?? "1512x982").split(separator: "x").compactMap { Double($0) }
        guard size.count == 2 else { throw Failure(description: "Sizes look like 1512x982") }
        let scale = Double(options["scale"] ?? "2") ?? 2
        let time = Double(options["time"] ?? "20") ?? 20

        let gpu = try GPU()
        let frame = CGRect(x: 0, y: 0, width: size[0], height: size[1])
        var light = World.Light.alwaysDay
        var clock = date
        if let hour = options["hour"].flatMap(Double.init) {
            light = .yourTime
            var calendar = Calendar.current
            calendar.timeZone = .current
            clock = calendar.startOfDay(for: date).addingTimeInterval(hour * 3600)
        }
        let world = World(place: place, time: 0, date: date, light: .alwaysDay)
        world.pointer = { nil }
        world.now = { clock }
        world.light = light
        world.home = frame
        world.desktop = frame
        world.centreRiver(on: frame)
        world.advance(to: time)
        let renderer = ViewRenderer(gpu: gpu)
        renderer.configure(frame: frame, scale: scale)

        let width = Int(size[0] * scale), height = Int(size[1] * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
        renderer.encode(world: world, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }

        try write(target, to: URL(filePath: output))
        let gpuTime = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        print(String(format: "%@ · %@ · %.2f ms GPU", place.name, place.season(on: date).line, gpuTime))
    }

    static func write(_ texture: MTLTexture, to url: URL) throws {
        let width = texture.width, height = texture.height
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "Could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "Could not write \(url.path)") }
    }
}
