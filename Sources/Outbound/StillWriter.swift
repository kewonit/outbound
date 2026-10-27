import AppKit
@preconcurrency import Metal
import UniformTypeIdentifiers

/// Shows the painting on the lock screen by making it the real desktop picture while the Mac is locked, and puts
/// the user's own picture back once it has unlocked.
///
/// macOS keeps a picture for every desktop (Space) on every display, and an app can only change the one showing.
/// Nobody can move to another desktop while the Mac is locked, so a painting shown then always comes off the same
/// desktop it went on. Paintings left on other desktops by older versions, which set them all the time, are put
/// back whenever one of those desktops comes into view.
@MainActor
final class StillWriter {
    private let gpu: GPU
    private let defaults: UserDefaults
    private static let originalsKey = "originalDesktopPictures"
    /// How long the desktop takes to come back in view over the desktop picture, after the Mac unlocks or the
    /// desktop changes, with time to spare.
    private static let settling: TimeInterval = 2
    /// The Mac is locked, so the paintings stay where they are.
    private var locked = false
    /// Counts locks, so a painting finished late never lands over a newer one.
    private var locks = 0
    /// Counts restores put off, so only the latest one runs.
    private var restores = 0

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

    /// As the Mac locks: paints again the frame each wallpaper holds, the moment it carries on from once the Mac
    /// unlocks, and makes it that display's desktop picture, remembering the user's own first. The lock screen and
    /// the desktop under it then show the same painting, so nothing changes as one gives way to the other.
    func lock(showing wallpapers: some Sequence<Wallpaper>) {
        locked = true
        locks += 1
        let turn = locks
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The system caches desktop pictures by URL, so every painting gets a name of its own.
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        for wallpaper in wallpapers {
            let id = wallpaper.displayID
            let size = wallpaper.stillSize
            let width = Int(size.width), height = Int(size.height)
            guard width > 0, height > 0 else { continue }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = gpu.device.makeTexture(descriptor: descriptor),
                  let commands = gpu.queue.makeCommandBuffer() else { continue }
            wallpaper.encodeStill(into: target, commandBuffer: commands)
            let url = folder.appending(path: "lock-\(id)-\(stamp).jpg")
            commands.addCompletedHandler { [weak self] buffer in
                guard buffer.status == .completed else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard (try? Exporter.write(target, to: url, type: .jpeg)) != nil else { return }
                    DispatchQueue.main.async { self?.show(url, on: id, turn: turn) }
                }
            }
            commands.commit()
        }
    }

    private func show(_ url: URL, on id: CGDirectDisplayID, turn: Int) {
        defer { removePaintings(of: id, keeping: url) }
        // Unlocked meanwhile, or locked again with a newer painting on its way.
        guard locked, turn == locks, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        var originals = savedOriginals
        if let current = NSWorkspace.shared.desktopImageURL(for: screen), !isStill(current) {
            originals[String(id)] = Original(url: current, options: NSWorkspace.shared.desktopImageOptions(for: screen))
            // Saved before the picture changes, so a crash in between still knows what to put back.
            savedOriginals = originals
        }
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true
        ])
        Log.display.info("Display \(id) shows the painting on the lock screen")
    }

    /// Keeps the new painting, and whichever one is on the lock screen right now; older ones are shown nowhere.
    /// Paintings named display-… were set by older versions and may still be on a desktop not yet seen again, so they
    /// stay.
    private func removePaintings(of id: CGDirectDisplayID, keeping url: URL) {
        let shown = NSScreen.screens.first { $0.displayID == id }.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let keep = [url.lastPathComponent, shown?.lastPathComponent]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("lock-\(id)-") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// As the Mac unlocks: the paintings come off once the desktop is back in view over them. Put back at once, the
    /// user's own pictures would show through as the lock screen gives way to the desktop.
    func unlock() {
        locked = false
        restoreOnceSettled()
    }

    /// Puts the user's own pictures back once the desktop has settled in view over them, after the Mac unlocks, at
    /// launch, or on moving to another desktop. Asked again meanwhile, it waits from then.
    func restoreOnceSettled() {
        restores += 1
        let turn = restores
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settling) { [weak self] in
            guard let self, turn == restores else { return }
            restore()
        }
    }

    /// Puts the user's own picture back on every display showing a painting, on the desktop in view. Every
    /// display showing a picture of the user's own has it remembered, so a painting left on a desktop with no
    /// record of its own still gets the picture that display last had, or failing that another display's. While the
    /// Mac is locked the paintings stay on the lock screen, even as Outbound quits to install an update; they come
    /// off once it unlocks, or at the next launch.
    func restore() {
        guard !locked else { return }
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
            Log.display.info("Display \(key, privacy: .public) has the user's own picture back")
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
