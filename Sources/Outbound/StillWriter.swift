import AppKit
import Metal
import UniformTypeIdentifiers

/// Sets the real desktop picture to a painting of the current view, so the lock screen, the menu bar's
/// tint and the moment before launch all match. Remembers the picture it replaced so it can be put back.
@MainActor
final class StillWriter {
    private let gpu: GPU
    private let defaults: UserDefaults
    private var counter = 0
    private static let originalsKey = "originalDesktopPictures"

    init(gpu: GPU, defaults: UserDefaults = .standard) {
        self.gpu = gpu
        self.defaults = defaults
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Outbound/Stills", directoryHint: .isDirectory)
    }

    func capture(world: World) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The system caches desktop pictures by URL, so alternate between two names.
        counter = (counter + 1) % 2
        var originals = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let key = String(id)
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), !current.path.hasPrefix(folder.path),
               originals[key] == nil {
                originals[key] = current.absoluteString
            }
            let url = folder.appending(path: "display-\(id)-\(counter).jpg")
            do {
                try render(world: world, frame: screen.frame, scale: Double(screen.backingScaleFactor), to: url)
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ])
            } catch {
                Log.display.error("Could not set the still for \(id): \(String(describing: error), privacy: .public)")
            }
        }
        defaults.set(originals, forKey: Self.originalsKey)
    }

    var hasOriginals: Bool {
        !(defaults.dictionary(forKey: Self.originalsKey)?.isEmpty ?? true)
    }

    /// Puts back the pictures that were there before Outbound.
    func restore() {
        let originals = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let saved = originals[String(id)] ?? originals.values.first
            guard let saved, let url = URL(string: saved) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        defaults.removeObject(forKey: Self.originalsKey)
    }

    private func render(world: World, frame: CGRect, scale: Double, to url: URL) throws {
        let renderer = ViewRenderer(gpu: gpu)
        renderer.configure(frame: frame, scale: scale)
        let width = Int((Double(frame.width) * scale).rounded()), height = Int((Double(frame.height) * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
        renderer.encode(world: world, into: target, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        try Exporter.write(target, to: url, type: .jpeg)
    }
}
