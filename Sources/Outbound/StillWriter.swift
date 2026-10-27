import AppKit
@preconcurrency import Metal
import UniformTypeIdentifiers

/// Keeps a painting of the view as the real desktop picture while Outbound runs, so the lock screen, the login
/// window and Mission Control show the painting too, never the user's own picture for a moment first: the lock
/// screen comes up before anyone is told the Mac is locking. Puts the user's own picture back on quit.
///
/// macOS keeps a picture for every desktop (Space) on every display, and an app can only change the one in view. So
/// each painting is remembered with the picture it covers, by the painting's own file name, and a desktop still
/// showing one after Outbound quits gets its own picture back the next time it comes into view while Outbound runs.
@MainActor
final class StillWriter {
    private let gpu: GPU
    private let defaults: UserDefaults
    private static let originalsKey = "originalDesktopPictures"
    /// The Mac is locked, so the paintings stay where they are, even as Outbound quits to install an update.
    private var locked = false
    /// Counts paintings asked for and pictures put back, so a painting finished late never lands over a newer one,
    /// or over the user's own picture once it is back.
    private var turn = 0

    init(gpu: GPU, defaults: UserDefaults = .standard) {
        self.gpu = gpu
        self.defaults = defaults
        forgetOldPaintings()
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Outbound/Stills", directoryHint: .isDirectory)
    }

    private func isStill(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path)
    }

    private func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// When a painting was made, from its name.
    private static func made(_ url: URL) -> Date? {
        guard let stamp = Double(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "")
        else { return nil }
        return Date(timeIntervalSince1970: stamp / 1000)
    }

    /// A desktop showing a painting gets a new one whenever it comes into view, so a painting a month old is on a
    /// desktop nobody has been back to, or on none since the user chose a picture over it. It goes, with its record;
    /// should its desktop come into view again, it gets the picture its display last had.
    private func forgetOldPaintings() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var originals = savedOriginals
        for name in names where name.hasPrefix("painting-") || name.hasPrefix("lock-") {
            let url = folder.appending(path: name)
            guard let made = Self.made(url), Date.now.timeIntervalSince(made) > 30 * 24 * 3600 else { continue }
            try? FileManager.default.removeItem(at: url)
            originals[name] = nil
        }
        savedOriginals = originals
    }

    /// Paints again the frame each wallpaper holds and makes it that display's desktop picture, on the desktop in
    /// view. The GPU only composites what is already cached, and the JPEG is encoded on a background queue.
    func paint(_ wallpapers: some Sequence<Wallpaper>) {
        turn += 1
        let turn = turn
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The system caches desktop pictures by URL, so every painting gets a name of its own.
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        for wallpaper in wallpapers {
            let id = wallpaper.displayID
            let size = wallpaper.stillSize
            let width = Int(size.width), height = Int(size.height)
            guard width > 0, height > 0, let screen = screen(id),
                  let covered = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = gpu.device.makeTexture(descriptor: descriptor),
                  let commands = gpu.queue.makeCommandBuffer() else { continue }
            wallpaper.encodeStill(into: target, commandBuffer: commands)
            let url = folder.appending(path: "painting-\(id)-\(stamp).jpg")
            commands.addCompletedHandler { [weak self] buffer in
                guard buffer.status == .completed else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard (try? Exporter.write(target, to: url, type: .jpeg)) != nil else { return }
                    DispatchQueue.main.async { self?.show(url, on: id, covering: covered, turn: turn) }
                }
            }
            commands.commit()
        }
    }

    private func show(_ url: URL, on id: CGDirectDisplayID, covering covered: URL, turn: Int) {
        // A newer painting is on its way, or the user's own picture is back, or the user has moved to another desktop,
        // whose picture this painting would cover without knowing it.
        guard turn == self.turn, let screen = screen(id), NSWorkspace.shared.desktopImageURL(for: screen) == covered else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var originals = savedOriginals
        if isStill(covered) {
            // A painting over a painting covers the same picture.
            originals[url.lastPathComponent] = originals[covered.lastPathComponent]
        } else {
            let original = Original(url: covered, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            originals[url.lastPathComponent] = original
            // The picture this display last had, for a painting with no record of its own.
            originals[String(id)] = original
        }
        // Saved before the picture changes, so a crash in between still knows what to put back.
        savedOriginals = originals
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ])
        } catch {
            originals[url.lastPathComponent] = nil
            savedOriginals = originals
            try? FileManager.default.removeItem(at: url)
            return
        }
        Log.display.info("Display \(id) has a painting for its desktop picture")
        if isStill(covered) {
            originals[covered.lastPathComponent] = nil
            savedOriginals = originals
            try? FileManager.default.removeItem(at: covered)
        }
    }

    /// Whether each wallpaper's display shows a painting made in the last `seconds`, on the desktop in view.
    func isPainted(_ wallpapers: some Sequence<Wallpaper>, within seconds: TimeInterval = .infinity) -> Bool {
        wallpapers.allSatisfy { wallpaper in
            guard let screen = screen(wallpaper.displayID), let current = NSWorkspace.shared.desktopImageURL(for: screen),
                  isStill(current), let made = Self.made(current) else { return false }
            return Date.now.timeIntervalSince(made) < seconds
        }
    }

    /// As the Mac locks: the painting on the lock screen becomes the very frame each wallpaper holds, the moment it
    /// carries on from as the Mac unlocks, so the desktop comes back without a change.
    func lock(showing wallpapers: some Sequence<Wallpaper>) {
        locked = true
        paint(wallpapers)
    }

    func unlock() {
        locked = false
    }

    /// Puts the user's own picture back on every display showing a painting, on the desktop in view: the one that
    /// painting covers, or failing that the one the display last had, or another display's. Every display showing a
    /// picture of the user's own has it remembered. While the Mac is locked the paintings stay on the lock screen.
    func restore() {
        guard !locked else { return }
        turn += 1
        var originals = savedOriginals
        var showing: [(NSScreen, URL)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let current = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            if isStill(current) {
                showing.append((screen, current))
            } else {
                originals[String(id)] = Original(url: current, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            }
        }
        let fallback = originals.first { Int($0.key) != nil }?.value ?? originals.values.first
        for (screen, painting) in showing {
            let original = originals[painting.lastPathComponent]
                ?? screen.displayID.flatMap { originals[String($0)] } ?? fallback
            originals[painting.lastPathComponent] = nil
            Log.display.info("Display \(screen.displayID ?? 0) has the user's own picture back")
            if let original,
               (try? NSWorkspace.shared.setDesktopImageURL(original.url, for: screen, options: original.options)) != nil {
                try? FileManager.default.removeItem(at: painting)
                continue
            }
            // Nothing known, or the picture has gone, say with an external drive unplugged: the system's own.
            let system = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic")
            try? NSWorkspace.shared.setDesktopImageURL(system, for: screen, options: [:])
            try? FileManager.default.removeItem(at: painting)
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
