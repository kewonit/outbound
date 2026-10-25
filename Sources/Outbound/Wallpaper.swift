import AppKit
import OutboundCore
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
    /// Pixels drawn per point; below the backing scale, Core Animation scales the drawable up.
    var renderScale: Double? {
        didSet { updateDrawableSize() }
    }

    private func updateDrawableSize() {
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let scale = renderScale ?? Double(metalLayer.contentsScale)
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
}

/// The wallpaper on one display: its window, its renderer and the clock that drives it.
@MainActor
final class Wallpaper: NSObject {
    enum Hold: Hashable {
        case user, occluded, asleep, locked, inactive, lowPower, resting
    }

    let displayID: CGDirectDisplayID
    private let window: WallpaperWindow
    private let view: MetalView
    private let renderer: ViewRenderer
    private let world: World
    private let gpu: GPU
    private let label = CaptionView(frame: .zero)
    private var captionUpdated = -TimeInterval.infinity
    private var link: CADisplayLink?
    private(set) var holds: Set<Hold> = []
    private var observers: [NSObjectProtocol] = []
    /// A line under the caption, for development builds and licensing.
    var note: String?
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
        let container = NSView()
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.addSubview(label)
        window.contentView = container
        view.frame = container.bounds
        place(on: screen)
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
        place(on: screen)
        let backing = Double(screen.backingScaleFactor)
        renderer.configure(frame: screen.frame, scale: economical && backing > 1.5 ? 1.5 : backing)
    }

    /// Keeps the label in the corner of the usable area, clear of the Dock.
    private func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        label.frame = CGRect(x: visible.minX - screen.frame.minX + 20, y: visible.minY - screen.frame.minY + 18,
                             width: 1, height: 1)
    }

    private func updateCaption() {
        let mpp = World.metresPerPoint
        let frame = window.frame
        let centre = world.camera + SIMD2(Double(frame.midX), Double(frame.midY)) * mpp
        let leg = world.journey.leg(at: centre.y)
        label.update(place: leg.place.name, season: leg.season.line,
                     coordinates: Geo.caption(world.journey.coordinate(x: centre.x, y: centre.y)), note: note)
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

    var halfRateClouds: Bool {
        get { renderer.halfRateClouds }
        set { renderer.halfRateClouds = newValue }
    }

    /// On battery a Retina display draws at 1.5x and lets Core Animation scale it up: almost half the pixels.
    var economical = false {
        didSet {
            guard economical != oldValue, let screen = window.screen else { return }
            let backing = Double(screen.backingScaleFactor)
            let scale = economical && backing > 1.5 ? 1.5 : backing
            view.renderScale = scale
            renderer.configure(frame: screen.frame, scale: scale)
        }
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
        if link.targetTimestamp - captionUpdated > 0.5 {
            captionUpdated = link.targetTimestamp
            updateCaption()
        }
        guard let drawable = view.metalLayer.nextDrawable(),
              let commands = gpu.queue.makeCommandBuffer() else { return }
        renderer.encode(world: world, into: drawable.texture, commandBuffer: commands)
        commands.present(drawable)
        #if DEBUG
        commands.addCompletedHandler { [weak self] buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.record(milliseconds) }
        }
        #endif
        commands.commit()
    }

    #if DEBUG
    private var statsStart = CACurrentMediaTime()
    private var statsFrames = 0
    private var statsGPU = 0.0

    /// Logs frames per second and GPU time every ten seconds while developing.
    private func record(_ milliseconds: Double) {
        statsFrames += 1
        statsGPU += milliseconds
        let elapsed = CACurrentMediaTime() - statsStart
        guard elapsed > 10 else { return }
        Log.render.info("Display \(self.displayID): \(Double(self.statsFrames) / elapsed, format: .fixed(precision: 1)) fps, \(self.statsGPU / Double(self.statsFrames), format: .fixed(precision: 2)) ms GPU")
        statsStart = CACurrentMediaTime()
        statsFrames = 0
        statsGPU = 0
    }
    #endif
}
