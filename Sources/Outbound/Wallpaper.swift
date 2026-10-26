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

    init(device: MTLDevice, opaque: Bool = true) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = ShaderLibrary.viewFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.isOpaque = opaque
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
    /// The bird's own small layer, so following the cursor smoothly never means redrawing the whole landscape.
    private let birdView: MetalView
    private var birdLink: FrameClock?
    /// Counts hand-overs between the landscape and the bird's layer, so only the latest one takes effect.
    private var birdHandOvers = 0
    private static let birdBox = 120.0
    var birdFramesPerSecond: Float = 60 {
        didSet { birdLink?.rate = birdFramesPerSecond }
    }
    private var captionUpdated = -TimeInterval.infinity
    private var hasDrawn = false
    private var link: FrameClock?
    /// How long one refresh of this display lasts, as of the last frame.
    private var refresh = 1.0 / 60
    private(set) var holds: Set<Hold> = []
    private var observers: [NSObjectProtocol] = []
    /// A line under the caption, for development builds and licensing.
    var note: String?
    var framesPerSecond: Float = 30 {
        didSet { if framesPerSecond != oldValue { applyFrameRate() } }
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID, world: World, gpu: GPU) {
        self.displayID = displayID
        self.world = world
        self.gpu = gpu
        window = WallpaperWindow(screen: screen)
        view = MetalView(device: gpu.device)
        renderer = ViewRenderer(gpu: gpu)
        birdView = MetalView(device: gpu.device, opaque: false)
        birdView.metalLayer.presentsWithTransaction = true
        super.init()
        let container = NSView()
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.addSubview(birdView)
        container.addSubview(label)
        birdView.isHidden = true
        window.contentView = container
        view.frame = container.bounds
        place(on: screen)
        applyScale(on: screen)
        window.orderFrontRegardless()

        link = FrameClock(view: view, display: displayID) { [weak self] tick in self?.tick(tick) }
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
        applyScale(on: screen)
    }

    /// On battery a Retina display draws at 1.5x and lets Core Animation scale it up: almost half the pixels.
    /// The drawable and the renderer always change together, or the cache would tile across the screen.
    private func applyScale(on screen: NSScreen) {
        let backing = Double(screen.backingScaleFactor)
        let scale = economical && backing > 1.5 ? 1.5 : backing
        view.renderScale = scale == backing ? nil : scale
        // On a display that isn't Retina each ground texel is a whole pixel, and the panning painting shimmers as
        // each frame lands it at a different fraction of one. Painted with half as many texels again and read through
        // a box the size of a pixel, it holds steady and stays as sharp.
        let steadies = backing < 1.75
        renderer.groundFilter = steadies ? 1 : 0
        renderer.configure(frame: screen.frame, scale: scale, density: steadies ? scale * 1.5 : scale)
    }

    /// Keeps the label in the corner of the usable area, clear of the Dock.
    private func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        label.frame = CGRect(x: visible.minX - screen.frame.minX + 20, y: visible.minY - screen.frame.minY + 18,
                             width: 1, height: 1)
    }

    private func updateCaption() {
        let centre = world.camera.y + Double(window.frame.midY) * World.metresPerPoint
        label.update(place: world.journey.leg(at: centre).place.name, note: note)
    }

    func close() {
        link?.invalidate()
        link = nil
        birdLink?.invalidate()
        birdLink = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        window.orderOut(nil)
        window.close()
    }

    func set(_ hold: Hold, _ on: Bool) {
        if on { holds.insert(hold) } else { holds.remove(hold) }
        let paused = !holds.isEmpty
        if link?.isPaused != paused {
            link?.isPaused = paused
            if !paused, !renderer.drawsBird {
                // The bird was on its own layer when the display was held; it carries on there.
                startBirdLink()
            }
            if paused {
                birdLink?.invalidate()
                birdLink = nil
                // Held before its first frame, say in Low Power Mode, it would show a blank window over the desktop
                // picture; paint once so it holds a still painting instead.
                if !hasDrawn { DispatchQueue.main.async { [weak self] in self?.drawStill() } }
            }
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

    var economical = false {
        didSet {
            guard economical != oldValue,
                  let screen = window.screen ?? NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
            applyScale(on: screen)
        }
    }

    private func occlusionChanged() {
        set(.occluded, !window.occlusionState.contains(.visible))
        onOcclusionChange()
    }

    /// Called when this wallpaper is covered or uncovered.
    var onOcclusionChange: () -> Void = {}

    private func applyFrameRate() {
        link?.rate = framesPerSecond
    }

    /// Whether the bird belongs on this display's own layer at `time`: chasing the cursor, and near this display.
    private func birdWantsLayer(at time: TimeInterval) -> Bool {
        guard world.chasing, link?.isPaused == false else { return false }
        let frame = window.frame
        let point = world.birdPose(at: time).position - SIMD2(Double(frame.minX), Double(frame.minY))
        let box = Self.birdBox
        return point.x > -box && point.y > -box && point.x < Double(frame.width) + box
            && point.y < Double(frame.height) + box
    }

    /// Gliding on its own, the bird is painted with the landscape at no extra cost. Chasing the cursor, it moves to a
    /// layer of its own with a display link of its own, so it follows smoothly without the whole landscape redrawing
    /// to keep up. The hand-over waits for the landscape frame that stops or starts painting it, which reaches the
    /// screen at `presentTime`, so the bird never blinks out or shows twice.
    private func handOverBird(at moment: TimeInterval, presenting presentTime: TimeInterval) {
        let wantsLayer = birdWantsLayer(at: moment)
        guard wantsLayer == renderer.drawsBird else { return }
        renderer.drawsBird = !wantsLayer
        birdHandOvers += 1
        let handOver = birdHandOvers
        DispatchQueue.main.asyncAfter(deadline: .now() + max(presentTime - CACurrentMediaTime(), 0)) { [weak self] in
            guard let self, birdHandOvers == handOver else { return }
            // Held meanwhile: resuming starts the bird's layer instead.
            if wantsLayer, link?.isPaused != false { return }
            #if DEBUG
            let late = (CACurrentMediaTime() - presentTime) * 1000
            stats.note(String(format: "bird to %@ %.0f ms late", wantsLayer ? "layer" : "landscape", late.rounded()))
            #endif
            if wantsLayer {
                startBirdLink()
                drawBird(at: world.renderTime(for: presentTime + refresh))
            } else {
                birdLink?.invalidate()
                birdLink = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                birdView.isHidden = true
                CATransaction.commit()
            }
        }
    }

    private func startBirdLink() {
        guard birdLink == nil else { return }
        let link = FrameClock(view: birdView, display: displayID) { [weak self] tick in self?.birdTick(tick) }
        link.rate = birdFramesPerSecond
        birdLink = link
    }

    /// Moves the bird's layer and paints the bird in it as it is at `time`, both in one transaction, so the picture
    /// and its place always change together.
    private func drawBird(at time: TimeInterval) {
        let frame = window.frame
        let pose = world.birdPose(at: time)
        let point = pose.position - SIMD2(Double(frame.minX), Double(frame.minY))
        let box = Self.birdBox
        let scale = Double(window.backingScaleFactor)
        let size = CGSize(width: box * scale, height: box * scale)
        let layer = birdView.metalLayer
        if layer.drawableSize != size || layer.contentsScale != CGFloat(scale) {
            layer.contentsScale = CGFloat(scale)
            layer.drawableSize = size
        }
        guard let drawable = layer.nextDrawable(), let commands = gpu.birdQueue.makeCommandBuffer() else { return }
        renderer.encodeBird(world: world, at: time, into: drawable.texture, commandBuffer: commands, size: box,
                            scale: scale)
        commands.commit()
        commands.waitUntilScheduled()
        #if DEBUG
        if pose.position == lastBirdDrawn { stats.birdStalls += 1 } else { stats.birdMoves += 1 }
        lastBirdDrawn = pose.position
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        birdView.frame = CGRect(x: point.x - box / 2, y: point.y - box / 2, width: box, height: box)
        if birdView.isHidden { birdView.isHidden = false }
        drawable.present()
        CATransaction.commit()
    }

    private func birdTick(_ tick: FrameClock.Tick) {
        world.advance(to: tick.targetTimestamp)
        drawBird(at: world.renderTime(for: tick.targetTimestamp))
    }

    private func tick(_ tick: FrameClock.Tick) {
        refresh = tick.duration
        #if DEBUG
        let entered = CACurrentMediaTime()
        #endif
        // Frames go up at a set time. Going up whenever they are ready puts them on screen a refresh early or late at
        // random, which reads as judder however fast they are drawn. Asked for three quarters of a refresh before the
        // target, a frame reaches the screen one refresh after it, every time, so each frame shows the moment it is on
        // screen. Asking for a time the display could refresh at (ProMotion can every quarter of a refresh) leaves it
        // to rounding which side of it a frame lands.
        var presentTime = tick.targetTimestamp - tick.duration * 0.75
        var onScreen = tick.targetTimestamp + tick.duration
        #if DEBUG
        // OUTBOUND_PRESENT=half, refresh, target or now tries other ways of putting frames up, to compare.
        switch ProcessInfo.processInfo.environment["OUTBOUND_PRESENT"] {
        case "half": presentTime = tick.targetTimestamp - tick.duration / 2
        case "refresh": presentTime = tick.targetTimestamp - tick.duration; onScreen = tick.targetTimestamp
        case "target": presentTime = tick.targetTimestamp; onScreen = tick.targetTimestamp + tick.duration
        case "now": presentTime = .nan; onScreen = tick.targetTimestamp
        default: break
        }
        #endif
        world.advance(to: onScreen)
        let moment = world.renderTime(for: onScreen)
        handOverBird(at: moment, presenting: presentTime)
        if tick.targetTimestamp - captionUpdated > 0.5 {
            captionUpdated = tick.targetTimestamp
            updateCaption()
        }
        draw(at: moment, showing: onScreen, presentAt: presentTime)
        #if DEBUG
        stats.ticked(late: entered - tick.timestamp, took: CACurrentMediaTime() - entered, waited: drawableWait)
        stats.reportIfDue(rate: Double(framesPerSecond), refresh: tick.duration)
        #endif
    }

    /// One frame for a wallpaper that was held before it ever drew.
    private func drawStill() {
        guard !hasDrawn, link != nil else { return }
        view.layoutSubtreeIfNeeded()
        updateCaption()
        draw(at: world.time, showing: CACurrentMediaTime(), presentAt: nil)
    }

    /// Draws the world as it is at `moment`, for a frame meant to be on screen at `display` time, going up at
    /// `presentAt`, or as soon as it is ready.
    private func draw(at moment: TimeInterval, showing display: TimeInterval, presentAt: TimeInterval?) {
        #if DEBUG
        let asked = CACurrentMediaTime()
        #endif
        guard let drawable = view.metalLayer.nextDrawable(),
              let commands = gpu.queue.makeCommandBuffer() else { return }
        #if DEBUG
        drawableWait = CACurrentMediaTime() - asked
        #endif
        renderer.encode(world: world, at: moment, into: drawable.texture, commandBuffer: commands)
        let painted = renderer.paintedTexels
        commands.addCompletedHandler { [weak self] buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.renderer.finished(gpu: milliseconds, painted: painted) }
        }
        #if DEBUG
        renderer.events.forEach { stats.note($0) }
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            DispatchQueue.main.async { self?.stats.presented(at: time, showing: display) }
        }
        commands.addCompletedHandler { [weak self] buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.stats.finished(gpu: milliseconds, painted: painted) }
        }
        #endif
        if let presentAt, !presentAt.isNaN { commands.present(drawable, atTime: presentAt) } else { commands.present(drawable) }
        hasDrawn = true
        commands.commit()
    }

    #if DEBUG
    private lazy var stats = FrameStats(display: displayID)
    private var drawableWait = 0.0
    private var lastBirdDrawn: SIMD2<Double>?
    #endif
}
