import AppKit
@preconcurrency import Metal
import UniformTypeIdentifiers

/// Shows a painting of the current view on the lock screen by making it the real desktop picture while the Mac
/// is locked, and puts the user's own picture back as it unlocks.
///
/// macOS keeps a picture for every desktop (Space) on every display, and an app can only change the one showing.
/// Nobody can move to another desktop while the Mac is locked, so a painting shown then always comes off the same
/// desktop it went on. Paintings left on other desktops by older versions, which set them all the time, are put
/// back whenever one of those desktops comes into view.
@MainActor
final class StillWriter {
    private let gpu: GPU
    private let defaults: UserDefaults
    /// The latest painting of each display, ready to show the moment the Mac locks.
    private var ready: [CGDirectDisplayID: URL] = [:]
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

    /// Paints each display's view, ready for the lock screen, off the main thread's back: the GPU paints and a
    /// background queue encodes the JPEG. At 1x, so it never stalls a frame. Nothing on screen changes.
    func prepare(world: World) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The system caches desktop pictures by URL, so every painting gets a name of its own.
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let width = Int(screen.frame.width.rounded()), height = Int(screen.frame.height.rounded())
            guard width > 0, height > 0 else { continue }
            let url = folder.appending(path: "lock-\(id)-\(stamp).jpg")
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
                DispatchQueue.main.async { [weak self] in self?.paintingReady(url, for: id) }
            }
            commands.commit()
        }
    }

    private func paintingReady(_ url: URL, for id: CGDirectDisplayID) {
        ready[id] = url
        // Keep the new painting, and whichever one is on the lock screen right now; older ones are shown nowhere.
        // Paintings named display-… were set by older versions and may still be on a desktop not yet seen again,
        // so they stay.
        let shown = NSScreen.screens.first { $0.displayID == id }.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let keep = [url.lastPathComponent, shown?.lastPathComponent]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("lock-\(id)-") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Makes the ready paintings the desktop pictures, as the Mac locks, remembering the user's own first.
    func show() {
        var originals = savedOriginals
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let url = ready[id] else { continue }
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isStill(current) {
                originals[String(id)] = Original(url: current, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            }
            // Saved before the picture changes, so a crash in between still knows what to put back.
            savedOriginals = originals
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ])
        }
    }

    /// Puts the user's own picture back on every display showing a painting, on the desktop in view. Every
    /// display showing a picture of the user's own has it remembered, so a painting left on a desktop with no
    /// record of its own still gets the picture that display last had, or failing that another display's.
    func restore() {
        var originals = savedOriginals
        var showing: [(NSScreen, String)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let current = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            let key = String(id)
            if isStill(current) {
                showing.append((screen, key))
            } else {
                originals[key] = Original(url: current, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            }
        }
        let fallback = originals.values.first
        for (screen, key) in showing {
            if let original = originals[key] ?? fallback,
               (try? NSWorkspace.shared.setDesktopImageURL(original.url, for: screen, options: original.options)) != nil {
                continue
            }
            // Nothing known, or the picture has gone, say with an external drive unplugged: the system's own.
            let system = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic")
            try? NSWorkspace.shared.setDesktopImageURL(system, for: screen, options: [:])
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
