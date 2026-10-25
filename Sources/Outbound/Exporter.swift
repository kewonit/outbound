import AppKit
import Metal
import OutboundCore
import UniformTypeIdentifiers

/// Renders frames to files without opening any windows, for checking the painting and for making
/// videos of it:
///
///     Outbound --render out.png [--place punjab] [--date 2026-04-20] [--hour 16.5] [--time 20]
///                               [--size 1512x982] [--scale 2]
///     Outbound --render - --seconds 20 --fps 30 ... | ffmpeg -f rawvideo -pix_fmt bgra -s WxH -r 30 -i - out.mp4
///     Outbound --icon icon.png
///     Outbound --dmg background.png [--scale 2]
///
/// Without --hour the light is always fair daytime; with it the sun stands where it would at that hour.
@MainActor
enum Exporter {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--render") || arguments.contains("--icon") || arguments.contains("--dmg")
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
            if let path = options["icon"] {
                try icon(to: URL(filePath: path))
            } else if let path = options["dmg"] {
                try diskImage(to: URL(filePath: path), scale: Double(options["scale"] ?? "1") ?? 1)
            } else {
                try render(options)
            }
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
        var time = Double(options["time"] ?? "20") ?? 20

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
        world.isDesktop = { _ in false }
        world.now = { clock }
        world.light = light
        world.home = frame
        world.desktop = frame
        world.centreRiver(on: frame)
        if options["still"] != nil { world.journey.setSpeed(0, at: 0) }
        if options["best"] != nil {
            // Each place in the season it is known for, rather than the one it is in on --date.
            world.journey.followsCalendar = false
            world.journey.refreshSeasons()
        }
        world.advance(to: time)
        // With --find train or --find flock, fly on until one is in view.
        if let event = options["find"] {
            while time < 7200 {
                if event == "train" ? world.trainPassing : world.flock != nil { break }
                time += 2
                world.advance(to: time)
            }
            print(String(format: "Found %@ at %.0f s", event, time))
            time += Double(options["after"] ?? "0") ?? 0
            world.advance(to: time)
            if ProcessInfo.processInfo.environment["DEBUG_TRAIN"] != nil {
                let f = world.frame(bottom: 0, top: 1)
                let t = f.scene.train
                let w = Double(t.run.x) / Double(t.shape.y) + Double(t.shape.z)
                let across = Double(t.shape.x) * sin(w)
                let a = Double(t.rail.z)
                let nose = SIMD2(Double(t.rail.x) + Double(t.run.x) * cos(a) - across * sin(a),
                                 Double(t.rail.y) + Double(t.run.x) * sin(a) + across * cos(a) + f.reference)
                let pixel = (nose - world.camera) / World.metresPerPoint
                print("train", t.rail, t.shape, t.run, "nose world", nose, "nose point", pixel)
            }
        }
        let renderer = ViewRenderer(gpu: gpu)
        renderer.configure(frame: frame, scale: scale)

        let width = Int(size[0] * scale), height = Int(size[1] * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: descriptor) else { throw Failure(description: "No GPU") }

        // With --bench, fly for a while and report GPU time per frame, without writing anything.
        if let seconds = options["bench"].flatMap(Double.init) {
            let fps = Double(options["fps"] ?? "30") ?? 30
            var times: [Double] = []
            for frame in 0..<Int(seconds * fps) {
                world.advance(to: time + Double(frame) / fps)
                guard let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
                renderer.encode(world: world, into: target, commandBuffer: commands)
                commands.commit()
                commands.waitUntilCompleted()
                if frame > 2 { times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000) }
            }
            times.sort()
            let mean = times.reduce(0, +) / Double(max(times.count, 1))
            print(String(format: "%@ %dx%d: median %.3f ms, mean %.3f ms, p95 %.3f ms over %d frames", place.id,
                         width, height, times[times.count / 2], mean, times[times.count * 95 / 100], times.count))
            return
        }

        // With --seconds, stream raw BGRA frames to standard output for ffmpeg, flying on between them.
        if let seconds = options["seconds"].flatMap(Double.init) {
            let fps = Double(options["fps"] ?? "30") ?? 30
            let out = FileHandle.standardOutput
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for frame in 0..<Int(seconds * fps) {
                world.advance(to: time + Double(frame) / fps)
                guard let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
                renderer.encode(world: world, into: target, commandBuffer: commands)
                commands.commit()
                commands.waitUntilCompleted()
                target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                out.write(Data(bytes))
            }
            return
        }

        guard let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
        renderer.encode(world: world, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }

        let url = URL(filePath: output)
        try write(target, to: url, type: url.pathExtension == "jpg" ? .jpeg : .png)
        let gpuTime = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        let season = world.journey.leg(at: world.camera.y).season.line
        print(String(format: "%@ · %@ · %.2f ms GPU", place.name, season, gpuTime))
    }

    /// A still of a place in fair daylight, with the bird where it is asked to be.
    private static func paint(_ place: Place, season: Int, frame: CGRect, scale: Double, bird: (CGPoint, Double)?,
                              birdSize: Double = 27, time: Double = 30) throws -> CGImage {
        let gpu = try GPU()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: place.seasons[season].months.min() ?? 1, day: 15))!
        let world = World(place: place, time: 0, date: date, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        world.home = frame
        world.desktop = frame
        world.centreRiver(on: frame)
        world.advance(to: time)
        if let bird { world.poseBird(at: bird.0, heading: bird.1) }
        let renderer = ViewRenderer(gpu: gpu)
        renderer.configure(frame: frame, scale: scale)
        renderer.finish = SIMD4(1, 0, 0, 0)
        renderer.birdSize = bird == nil ? 0 : birdSize
        let width = Int((Double(frame.width) * scale).rounded()), height = Int((Double(frame.height) * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
        renderer.encode(world: world, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        return try image(target)
    }

    /// The app icon: a square of painted fields with the bird crossing it, cut to the macOS icon shape.
    private static func icon(to url: URL) throws {
        let painting = try paint(Place.named("punjab")!, season: 0, frame: CGRect(x: 0, y: 0, width: 512, height: 512),
                                 scale: 1024.0 / 512, bird: (CGPoint(x: 262, y: 268), 0.75), birdSize: 92)
        let size = 1024
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Apple's grid: an 824 point body centred on a 1024 canvas.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.addPath(shape)
        context.clip()
        context.draw(painting, in: body)
        context.resetClip()
        context.addPath(shape)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 0.35))
        context.setLineWidth(6)
        context.strokePath()
        try save(context.makeImage()!, to: url, type: .png)
    }

    /// The disk image window: warm paper with a torn strip of painted paddies along the bottom, and a
    /// pencil arrow from the app to Applications.
    private static func diskImage(to url: URL, scale: Double) throws {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 360)
        let painting = try paint(Place.named("niigata")!, season: 0, frame: frame, scale: scale, bird: nil)
        let width = Int(600 * scale), height = Int(360 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.draw(painting, in: frame)

        // Paper over everything but a strip at the bottom, its lower edge torn.
        var random = SplitMix(seed: 11)
        let paper = CGMutablePath()
        paper.move(to: CGPoint(x: 0, y: 360))
        paper.addLine(to: CGPoint(x: 600, y: 360))
        var x = 600.0
        while x >= 0 {
            paper.addLine(to: CGPoint(x: x, y: 92 + (random.next() - 0.5) * 3.2 + sin(x / 47) * 2.2))
            x -= 3
        }
        paper.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.22))
        context.setFillColor(CGColor(srgbRed: 0.982, green: 0.968, blue: 0.935, alpha: 1))
        context.addPath(paper)
        context.fillPath()
        context.restoreGState()

        // A pencil arrow, drawn a little unevenly.
        context.setStrokeColor(CGColor(srgbRed: 0.33, green: 0.31, blue: 0.29, alpha: 0.85))
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 268, y: 200))
        arrow.addCurve(to: CGPoint(x: 332, y: 201.5), control1: CGPoint(x: 290, y: 203), control2: CGPoint(x: 312, y: 199))
        arrow.move(to: CGPoint(x: 322, y: 209))
        arrow.addLine(to: CGPoint(x: 333, y: 201.5))
        arrow.addLine(to: CGPoint(x: 321.5, y: 194))
        context.addPath(arrow)
        context.strokePath()
        try save(context.makeImage()!, to: url, type: .png)
    }

    private static func save(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failure(description: "Could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "Could not write \(url.path)") }
    }

    private static func image(_ texture: MTLTexture) throws -> CGImage {
        let width = texture.width, height = texture.height
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw Failure(description: "Could not read the frame back") }
        return image
    }

    nonisolated static func write(_ texture: MTLTexture, to url: URL, type: UTType = .png) throws {
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
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failure(description: "Could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "Could not write \(url.path)") }
    }
}
