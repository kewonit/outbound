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
///     Outbound --og preview.png
///
/// For the website: --caption adds the place name in the corner as on the desktop, and --dock 58 leaves that
/// many points for a Dock along the bottom, so the caption sits above it as it does on a Mac. --cursor flies a
/// pointer across the frame for the bird to chase, and --fly-to lisse --fly-at 3 picks Lisse from the menu
/// after three seconds. --pace sets metres per second over the ground.
///
/// Without --hour the light is always fair daytime; with it the sun stands where it would at that hour.
@MainActor
enum Exporter {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--render") || arguments.contains("--icon") || arguments.contains("--dmg")
            || arguments.contains("--og")
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
            } else if let path = options["og"] {
                try linkPreview(to: URL(filePath: path))
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
        if let pace = options["pace"].flatMap(Double.init) { world.journey.setSpeed(pace, at: 0) }
        // A pointer that wanders over the frame and rests now and then, for the bird to chase.
        let cursor = options["cursor"] != nil
        var clockTime = time
        if cursor {
            world.isDesktop = { _ in true }
            world.pointer = { cursorPoint(at: clockTime, in: frame) }
        }
        world.advance(to: time)
        // With --find train or --find flock, fly on until one is in view.
        if let event = options["find"] {
            while time < 7200 {
                if event == "train" ? world.trainPassing : world.flock != nil { break }
                time += 2
                world.advance(to: time)
            }
            // On standard error, so a video streaming to standard output stays clean.
            FileHandle.standardError.write(Data(String(format: "Found %@ at %.0f s\n", event, time).utf8))
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

        let caption = options["caption"] != nil
        let dock = Double(options["dock"] ?? "0") ?? 0
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func paintFrame() throws -> Double {
            guard let commands = gpu.queue.makeCommandBuffer() else { throw Failure(description: "No GPU") }
            renderer.encode(world: world, into: target, commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            if caption || cursor {
                let centre = world.camera.y + Double(frame.midY) * World.metresPerPoint
                overlay(&bytes, width: width, height: height, scale: scale,
                        caption: caption ? world.journey.leg(at: centre).place.name : nil, dock: dock,
                        cursor: cursor ? cursorPoint(at: clockTime, in: frame) : nil)
            }
            return (commands.gpuEndTime - commands.gpuStartTime) * 1000
        }

        // With --seconds, stream raw BGRA frames to standard output for ffmpeg, flying on between them.
        if let seconds = options["seconds"].flatMap(Double.init) {
            let fps = Double(options["fps"] ?? "30") ?? 30
            let destination = options["fly-to"].flatMap(Place.named)
            var flyAt = Double(options["fly-at"] ?? "3") ?? 3
            let out = FileHandle.standardOutput
            for frame in 0..<Int(seconds * fps) {
                clockTime = time + Double(frame) / fps
                world.advance(to: clockTime)
                if let destination, Double(frame) / fps >= flyAt {
                    let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
                    world.journey.fly(to: destination, from: bottom, time: world.time)
                    flyAt = .infinity
                }
                _ = try paintFrame()
                out.write(Data(bytes))
            }
            return
        }

        let gpuTime = try paintFrame()
        let url = URL(filePath: output)
        try save(try image(bytes, width: width, height: height), to: url, type: url.pathExtension == "jpg" ? .jpeg : .png)
        let season = world.journey.leg(at: world.camera.y).season.line
        print(String(format: "%@ · %@ · %.2f ms GPU", place.name, season, gpuTime))
    }

    /// A still of a place, in fair daylight or at a given hour, with the bird where it is asked to be.
    private static func paint(_ place: Place, season: Int, frame: CGRect, scale: Double, bird: (CGPoint, Double)?,
                              birdSize: Double = 27, time: Double = 30, hour: Double? = nil,
                              clouds: Bool = true) throws -> CGImage {
        let gpu = try GPU()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: place.seasons[season].months.min() ?? 1, day: 15))!
        let world = World(place: place, time: 0, date: date, light: .alwaysDay)
        world.pointer = { nil }
        world.isDesktop = { _ in false }
        if !clouds { world.cloudCover = 0 }
        if let hour {
            let clock = Calendar.current.startOfDay(for: date).addingTimeInterval(hour * 3600)
            world.now = { clock }
            world.light = .yourTime
        }
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

    /// The picture shown when a link to the site is shared: the painting under a soft wash, with the app icon, the
    /// name, what it is and the price, 1200 by 630 pixels.
    private static func linkPreview(to url: URL) throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 420)
        let painting = try paint(Place.named("punjab")!, season: 0, frame: frame, scale: 1.5,
                                 bird: (CGPoint(x: 600, y: 250), 2.3), birdSize: 30, time: 34, clouds: false)
        let appIcon = try paint(Place.named("punjab")!, season: 0, frame: CGRect(x: 0, y: 0, width: 512, height: 512),
                                scale: 0.5, bird: (CGPoint(x: 262, y: 268), 0.75), birdSize: 92)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 1200, height: 630, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(painting, in: CGRect(x: 0, y: 0, width: 1200, height: 630))

        // A wash from the left, so the words sit on calm dark paint and the fields stay bright on the right.
        let wash = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.02, alpha: 0.82), CGColor(gray: 0.02, alpha: 0.55),
                                                           CGColor(gray: 0.02, alpha: 0)] as CFArray,
                              locations: [0, 0.42, 0.78])!
        context.drawLinearGradient(wash, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1200, y: 0), options: [])

        // The app icon, in the macOS squircle.
        let iconRect = CGRect(x: 72, y: 410, width: 120, height: 120)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 27, cornerHeight: 27, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 27, cornerHeight: 27, transform: nil))
        context.clip()
        context.draw(appIcon, in: iconRect)
        context.restoreGState()

        func write(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, at point: CGPoint, width: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = size * 0.12
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha),
                .kern: -size * 0.01, .paragraphStyle: style
            ])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let bounds = string.boundingRect(with: CGSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
            string.draw(with: CGRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                        options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
        write("Outbound", size: 76, weight: .bold, alpha: 1, at: CGPoint(x: 70, y: 384), width: 560)
        write("A painted world, flying by behind your desktop.", size: 34, weight: .medium, alpha: 0.92,
              at: CGPoint(x: 72, y: 282), width: 500)
        write("For Mac  ·  $7 + tax", size: 24, weight: .medium, alpha: 0.7, at: CGPoint(x: 72, y: 128), width: 500)
        try save(context.makeImage()!, to: url, type: .png)
    }

    /// The disk image window, 600 points wide: a strip of painted tulip fields torn across the top of a sheet of
    /// warm slate paper, the two icons on the paper, and a white arrow from the app to Applications. Finder writes
    /// the icon names itself, black in Light Mode and white in Dark Mode, so the paper is a middle tone that keeps
    /// either one readable. Icons sit at (170, 196) and (430, 196) in Finder's coordinates, 112 points across.
    /// The sheet runs 400 points down, more than the window shows, so its foot is always paper however tall
    /// Finder makes the title bar.
    private static func diskImage(to url: URL, scale: Double) throws {
        let top = 400.0
        let frame = CGRect(x: 0, y: 0, width: 600, height: top)
        let strip = CGRect(x: 0, y: top - 124, width: 600, height: 124)
        let painting = try paint(Place.named("lisse")!, season: 0, frame: strip.offsetBy(dx: 0, dy: -strip.minY),
                                 scale: scale, bird: (CGPoint(x: 452, y: 70), 2.6), birdSize: 22, time: 44, clouds: false)
        let width = Int(600 * scale), height = Int(top * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)

        // Warm slate paper with a faint grain, a touch lighter in the middle.
        context.setFillColor(CGColor(srgbRed: 0.475, green: 0.455, blue: 0.43, alpha: 1))
        context.fill(frame)
        let glow = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.06), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: top - 210), startRadius: 0,
                                   endCenter: CGPoint(x: 300, y: top - 210), endRadius: 340, options: [])
        var random = SplitMix(seed: 23)
        for _ in 0..<9000 {
            let x = random.next() * 600, y = random.next() * strip.minY
            context.setFillColor(CGColor(gray: random.next() < 0.5 ? 0 : 1, alpha: 0.035 + 0.03 * random.next()))
            context.fill(CGRect(x: x, y: y, width: 0.7, height: 0.7))
        }

        // The painting, torn along its lower edge, lying on the paper with a soft shadow.
        let torn = CGMutablePath()
        torn.move(to: CGPoint(x: 0, y: top))
        torn.addLine(to: CGPoint(x: 600, y: top))
        var x = 600.0
        while x >= 0 {
            torn.addLine(to: CGPoint(x: x, y: strip.minY + (random.next() - 0.5) * 3 + sin(x / 53) * 2.4))
            x -= 2.5
        }
        torn.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: CGColor(gray: 0, alpha: 0.38))
        context.addPath(torn)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(torn)
        context.clip()
        context.draw(painting, in: strip.insetBy(dx: 0, dy: -4).offsetBy(dx: 0, dy: 4))
        context.restoreGState()

        // The arrow, from the app to Applications, rising a little as it goes.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: CGColor(gray: 0, alpha: 0.3))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let arrow = CGMutablePath()
        // Finder's y runs down from the top, so the icons' centre line is `top - 196` here.
        let y = top - 196
        arrow.move(to: CGPoint(x: 256, y: y - 4))
        arrow.addCurve(to: CGPoint(x: 342, y: y + 2), control1: CGPoint(x: 284, y: y + 8), control2: CGPoint(x: 316, y: y + 10))
        arrow.move(to: CGPoint(x: 331, y: y + 12))
        arrow.addLine(to: CGPoint(x: 343, y: y + 2))
        arrow.addLine(to: CGPoint(x: 330, y: y - 6))
        context.addPath(arrow)
        context.strokePath()
        context.restoreGState()

        // What to do, along the bottom.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -0.5)
        let line = NSAttributedString(string: "Drag Outbound into Applications", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.9),
            .shadow: shadow, .kern: 0.2
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        line.draw(at: CGPoint(x: 300 - line.size().width / 2, y: top - 330))
        NSGraphicsContext.restoreGraphicsState()
        try save(context.makeImage()!, to: url, type: .png)
    }

    /// Where the wandering pointer is at time `t`: sweeping loops across the middle of the frame, resting for a
    /// moment at the end of each.
    private static func cursorPoint(at t: Double, in frame: CGRect) -> CGPoint {
        let cycle = 9.0
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let moving = min(phase / 0.7, 1)
        let eased = moving * moving * (3 - 2 * moving)
        let loop = (t / cycle).rounded(.down) + eased
        let x = 0.5 + 0.3 * sin(loop * 2.1 + 0.4)
        let y = 0.5 + 0.24 * sin(loop * 3.3 + 1.2)
        return CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
    }

    /// Draws the caption and the pointer over a frame read back from the GPU, as they appear on the desktop.
    private static func overlay(_ bytes: inout [UInt8], width: Int, height: Int, scale: Double, caption: String?,
                                dock: Double, cursor: CGPoint?) {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: info) else { return }
            context.scaleBy(x: scale, y: scale)
            if let caption, let image = CaptionView.image(place: caption, note: nil, scale: scale) {
                let size = CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
                context.draw(image, in: CGRect(origin: CGPoint(x: 20 - CaptionView.margin, y: dock + 18 - CaptionView.margin),
                                               size: size))
            }
            if let cursor {
                // The system arrow: black with a white rim and a soft shadow, its tip at the point.
                let arrow = CGMutablePath()
                let points: [(Double, Double)] = [(0, 0), (0, 17), (4, 13.2), (7, 19.6), (9.6, 18.5), (6.8, 12.3), (12, 12.3)]
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: cursor.x + point.0, y: cursor.y - point.1)
                    if index == 0 { arrow.move(to: p) } else { arrow.addLine(to: p) }
                }
                arrow.closeSubpath()
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.addPath(arrow)
                context.setLineWidth(2.4)
                context.setLineJoin(.round)
                context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                context.drawPath(using: .fillStroke)
                context.restoreGState()
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.addPath(arrow)
                context.fillPath()
            }
        }
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw Failure(description: "Could not read the frame back") }
        return image
    }

    private static func save(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failure(description: "Could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
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
