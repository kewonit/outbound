import AppKit
@preconcurrency import Metal
import UniformTypeIdentifiers

/// Sets the real desktop picture to a painting of the current view, so the lock screen, the menu bar's
/// tint and the moment before launch all match. Remembers the picture it replaced on each display, with
/// how it was fitted, and puts it back on quit.
@MainActor
final class StillWriter {
    private let gpu: GPU
    private let defaults: UserDefaults
    /// Bumped on every restore, so a painting still on its way never lands after the user's picture is back.
    private var generation = 0
    private static let originalsKey = "originalDesktopPictures"

    init(gpu: GPU, defaults: UserDefaults = .standard) {
        self.gpu = gpu
        self.defaults = defaults
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Outbound/Stills", directoryHint: .isDirectory)
    }

    private func isStill(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path)
    }

    /// Paints each display's view off the main thread's back: the GPU paints, a background queue encodes the
    /// JPEG, and only setting the picture comes back to the main thread. At 1x, so it never stalls a frame.
    func capture(world: World) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The system caches desktop pictures by URL, so every painting gets a name of its own.
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        var originals = savedOriginals
        let generation = generation
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            // Whatever is there now and is not one of ours is the user's own, from before launch or chosen since.
            let current = NSWorkspace.shared.desktopImageURL(for: screen)
            if let current, !isStill(current) {
                originals[String(id)] = Original(url: current, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            }
            let width = Int(screen.frame.width.rounded()), height = Int(screen.frame.height.rounded())
            guard width > 0, height > 0 else { continue }
            let url = folder.appending(path: "display-\(id)-\(stamp).jpg")
            let folder = folder
            let renderer = ViewRenderer(gpu: gpu)
            renderer.configure(frame: screen.frame, scale: 1)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = gpu.device.makeTexture(descriptor: descriptor),
                  let commands = gpu.queue.makeCommandBuffer() else { continue }
            renderer.encode(world: world, into: target, commandBuffer: commands)
            commands.addCompletedHandler { buffer in
                guard buffer.status == .completed, (try? Exporter.write(target, to: url, type: .jpeg)) != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation,
                          let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                        .allowClipping: true
                    ])
                    // Keep the new painting and the one it replaced; older ones are no longer shown anywhere.
                    let keep = [url.lastPathComponent, current?.lastPathComponent]
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    for name in names where name.hasPrefix("display-\(id)-") && !keep.contains(name) {
                        try? FileManager.default.removeItem(at: folder.appending(path: name))
                    }
                }
            }
            commands.commit()
        }
        savedOriginals = originals
    }

    /// Puts back the pictures that were there before Outbound, on every display still showing a painting.
    /// A display the user has since given a picture of their own is left alone, and a display that is not
    /// connected right now keeps its entry, so it is put back the next time.
    func restore() {
        generation += 1
        var originals = savedOriginals
        let fallback = originals.values.first
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let key = String(id)
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen), isStill(current) else {
                originals[key] = nil
                continue
            }
            guard let original = originals[key] ?? fallback else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(original.url, for: screen, options: original.options)
            } catch {
                // The picture has gone, say an external drive is unplugged: fall back to the system's own.
                let system = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic")
                try? NSWorkspace.shared.setDesktopImageURL(system, for: screen, options: [:])
            }
            originals[key] = nil
        }
        savedOriginals = originals
    }

    // MARK: - Saved originals

    private struct Original {
        var url: URL
        var options: [NSWorkspace.DesktopImageOptionKey: Any]

        init(url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]?) {
            self.url = url
            self.options = options ?? [:]
        }

        init?(_ plist: Any) {
            // Early builds kept only the URL.
            if let string = plist as? String, let url = URL(string: string) {
                self.init(url: url, options: nil)
                return
            }
            guard let entry = plist as? [String: Any], let string = entry["url"] as? String,
                  let url = URL(string: string) else { return nil }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = entry["scaling"] as? Int { options[.imageScaling] = scaling }
            if let clipping = entry["clipping"] as? Bool { options[.allowClipping] = clipping }
            if let fill = entry["fill"] as? [Double], fill.count == 4 {
                options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
            }
            self.init(url: url, options: options)
        }

        var plist: [String: Any] {
            var entry: [String: Any] = ["url": url.absoluteString]
            if let scaling = (options[.imageScaling] as? NSNumber)?.intValue { entry["scaling"] = scaling }
            if let clipping = (options[.allowClipping] as? NSNumber)?.boolValue { entry["clipping"] = clipping }
            if let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
                entry["fill"] = [fill.redComponent, fill.greenComponent, fill.blueComponent, fill.alphaComponent]
                    .map { Double($0) }
            }
            return entry
        }
    }

    private var savedOriginals: [String: Original] {
        get {
            let stored = defaults.dictionary(forKey: Self.originalsKey) ?? [:]
            return stored.compactMapValues { Original($0) }
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.originalsKey)
            } else {
                defaults.set(newValue.mapValues(\.plist), forKey: Self.originalsKey)
            }
        }
    }
}
