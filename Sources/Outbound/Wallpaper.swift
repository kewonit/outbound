import AppKit
import QuartzCore

/// A borderless window that sits just below the desktop icons on every Space and lets every click
/// through to Finder.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        // Command-H would otherwise take the desktop down with it.
        canHide = false
        isOpaque = true
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        backgroundColor = NSColor(srgbRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MetalView: NSView {
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = ShaderLibrary.viewFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }

    private func updateDrawableSize() {
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                         height: bounds.height * metalLayer.contentsScale)
    }
}

/// The wallpaper on one display: its window, its renderer and the clock that drives it.
@MainActor
final class Wallpaper: NSObject {
    enum Hold: Hashable {
        case user, occluded, asleep, locked, inactive, lowPower
    }

    let displayID: CGDirectDisplayID
    private let window: WallpaperWindow
    private let view: MetalView
    private let renderer: ViewRenderer
    private let world: World
    private let gpu: GPU
    private var link: CADisplayLink?
    private(set) var holds: Set<Hold> = []
    private var observers: [NSObjectProtocol] = []
    var framesPerSecond: Float = 30 {
        didSet { applyFrameRate() }
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID, world: World, gpu: GPU) {
        self.displayID = displayID
        self.world = world
        self.gpu = gpu
        window = WallpaperWindow(screen: screen)
        view = MetalView(device: gpu.device)
        renderer = ViewRenderer(gpu: gpu)
        super.init()
        window.contentView = view
        renderer.configure(frame: screen.frame, scale: Double(screen.backingScaleFactor))
        window.orderFrontRegardless()

        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        applyFrameRate()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        })
        occlusionChanged()
    }

    func move(to screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        renderer.configure(frame: screen.frame, scale: Double(screen.backingScaleFactor))
    }

    func close() {
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        window.orderOut(nil)
        window.close()
    }

    func set(_ hold: Hold, _ on: Bool) {
        if on { holds.insert(hold) } else { holds.remove(hold) }
        let paused = !holds.isEmpty
        if link?.isPaused != paused {
            link?.isPaused = paused
            Log.display.info("Display \(self.displayID) \(paused ? "paused" : "running", privacy: .public) \(String(describing: self.holds), privacy: .public)")
        }
    }

    func repaint() {
        renderer.invalidate()
    }

    private func occlusionChanged() {
        set(.occluded, !window.occlusionState.contains(.visible))
    }

    private func applyFrameRate() {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: framesPerSecond * 0.8, maximum: framesPerSecond,
                                                         preferred: framesPerSecond)
    }

    @objc private func tick(_ link: CADisplayLink) {
        world.advance(to: link.targetTimestamp)
        guard let drawable = view.metalLayer.nextDrawable(),
              let commands = gpu.queue.makeCommandBuffer() else { return }
        renderer.encode(world: world, into: drawable.texture, commandBuffer: commands)
        commands.present(drawable)
        commands.commit()
    }
}
