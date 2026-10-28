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
        /// Every display's desktop is hidden, and Pause When Hidden holds the flight until one is in view again.
        case hidden
        /// The first frame is still being painted, before the window goes up.
        case starting
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

        link = FrameClock(view: view, display: displayID) { [weak self] tick in self?.tick(tick) }
        applyFrameRate()
        set(.starting, true)
        // As after a failed frame, a GPU in trouble isn't handed the ground again straight away.
        renderer.onGroundLost = { [weak self] in
            self?.catchUpAfter = CACurrentMediaTime() + 2
            self?.paintHeldGround()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        })
    }

    /// Paints the first frame straight away and puts the window up once it is presented, so the desktop picture gives way
    /// to the painting itself, not to an empty window, and nothing waits for the display link. The ground is painted
    /// first, in pieces any GPU paints quickly, while the desktop picture still shows. Should the GPU fail, the window
    /// stays down and the desktop picture with it. Called once the wallpaper is set up, so that frame already has the
    /// right border and scale.
    func show() {
        view.layoutSubtreeIfNeeded()
        updateCaption()
        world.advance(to: CACurrentMediaTime())
        catchUp { [weak self] in self?.showFirstFrame() }
    }

    private func showFirstFrame() {
        let now = CACurrentMediaTime()
        world.advance(to: now)
        let drawn = draw(at: world.renderTime(for: now), showing: now, presentAt: nil) { [weak self] in
            self?.reveal()
        }
        if !drawn { reveal() }
        // A frame that is never presented, say on a display not yet drawing, mustn't keep the window down for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reveal() }
    }

    private func reveal() {
        // Closed meanwhile, or up already.
        guard link != nil, holds.contains(.starting) else { return }
        window.orderFrontRegardless()
        let milliseconds = Int((CACurrentMediaTime() - OutboundApp.launched) * 1000)
        Log.display.info("Display \(self.displayID) up \(milliseconds) ms after launch")
        set(.starting, false)
        onStarted()
        revealing = true
        occlusionChanged()
    }

    /// Called as the window goes up, once its first frame is painted.
    var onStarted: () -> Void = {}

    /// Paints the ground the view needs now, in pieces of GPU work of their own (see `ViewRenderer.catchUp`), then calls
    /// `then`. Nothing new is drawn meanwhile, so the screen keeps what it shows. Started over by a change to the view,
    /// it begins again at once; should a piece fail, it tries again a little later, for as long as the GPU takes work.
    /// Without `then`, as frames ask, it starts now or not at all: frames ask again by themselves, and a display held
    /// meanwhile paints what is still missing (see `paintHeldGround`).
    private func catchUp(then: (@MainActor () -> Void)? = nil) {
        guard link != nil, !gpu.revoked else { return }
        let wait = catchUpAfter - CACurrentMediaTime()
        guard !renderer.isCatchingUp, wait <= 0 else {
            if let then {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(wait, 0.1)) { [weak self] in self?.catchUp(then: then) }
            }
            return
        }
        let time = world.renderTime(for: CACurrentMediaTime())
        // Painted meanwhile, say by another call.
        guard renderer.needsCatchUp(world: world, at: time) else {
            then?()
            return
        }
        renderer.catchUp(world: world, at: time) { [weak self] end in
            guard let self, link != nil else { return }
            if end == .failed { catchUpAfter = CACurrentMediaTime() + 2 }
            guard let then else {
                if end != .painted { DispatchQueue.main.async { [weak self] in self?.paintHeldGround() } }
                return
            }
            switch end {
            case .painted:
                then()
            case .superseded:
                DispatchQueue.main.async { [weak self] in self?.catchUp(then: then) }
            case .failed:
                catchUp(then: then)
            }
        }
    }

    /// When the ground may next be painted in pieces, a little after it failed, so a GPU in trouble isn't asked again
    /// every frame.
    private var catchUpAfter: CFTimeInterval = 0

    /// Up, and waiting to be seen: the window says so a moment after it goes up.
    private var revealing = false

    func move(to screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        place(on: screen)
        applyScale(on: screen)
        paintHeldGround()
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
        label.update(place: world.journey.placeShown(at: centre, time: world.time).name, note: note)
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
            }
            Log.display.info("Display \(self.displayID) \(paused ? "paused" : "running", privacy: .public) \(String(describing: self.holds), privacy: .public)")
        }
        // Waking, say, while something else still holds it.
        paintHeldGround()
    }

    /// Paints the ground afresh, at once if the display is held.
    func repaint() {
        renderer.invalidate()
        paintHeldGround()
    }

    /// Held, nothing is drawn, so ground emptied meanwhile, by a change of scale or display or by work the GPU dropped,
    /// would stay empty, and no painting of the desktop could be made from it. So it is painted and the held frame drawn
    /// again, unless the display is asleep, locked or covered by a full-screen app, the session is away or the first
    /// frame is still to come: nobody sees it then, nor is a painting made from it, and it is painted once they end.
    /// Locking draws again by itself, for the moment it goes back to.
    private func paintHeldGround() {
        guard link?.isPaused == true, holds.isDisjoint(with: [.starting, .asleep, .locked, .inactive, .occluded]),
              renderer.needsCatchUp(world: world, at: world.time) else { return }
        redraw()
    }

    /// The pixels a still of this display has, the same as its frames.
    var stillSize: CGSize { view.metalLayer.drawableSize }

    /// New light is still spreading over the ground, so a still now would show it half done.
    var isRepainting: Bool { renderer.isRepainting(for: world) }

    /// Paints the world as it is at `time` into `target`, for the desktop picture: from the same ground as the frames,
    /// with the bird in it even while it flies on a layer of its own. Encoded on the queue the frames use, so it
    /// follows them.
    func encodeStill(at time: TimeInterval, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let drawsBird = renderer.drawsBird
        renderer.drawsBird = true
        renderer.encode(world: world, at: time, into: target, commandBuffer: commandBuffer)
        renderer.drawsBird = drawsBird
    }

    /// Draws the world as it is now, held: after it has gone back to an earlier moment behind the lock screen, or
    /// when something changes while it is held. Ground that has to be painted afresh is painted first, in pieces.
    func redraw() {
        updateCaption()
        guard !renderer.needsCatchUp(world: world, at: world.time) else {
            catchUp { [weak self] in self?.drawHeld() }
            return
        }
        drawHeld()
    }

    private func drawHeld() {
        guard !gpu.revoked else { return }
        draw(at: world.time, showing: CACurrentMediaTime(), presentAt: nil)
        if !renderer.drawsBird { drawBird(at: world.time) }
    }

    var halfRateClouds: Bool {
        get { renderer.halfRateClouds }
        set { renderer.halfRateClouds = newValue }
    }

    var paperEdge: Bool {
        get { renderer.paperEdge }
        set { renderer.paperEdge = newValue }
    }

    var economical = false {
        didSet {
            guard economical != oldValue,
                  let screen = window.screen ?? NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
            applyScale(on: screen)
            paintHeldGround()
        }
    }

    /// Whether any of the window can be seen.
    var isVisible: Bool { window.occlusionState.contains(.visible) }

    /// App windows hide all of this display's desktop but strips and corners, which macOS doesn't say for a window at
    /// the desktop's level (see `CoverWatch`), read whenever anything is drawn. It holds with the others, or draws
    /// fewer frames.
    var coveredByWindows = false {
        didSet { if coveredByWindows != oldValue { onOcclusionChange() } }
    }

    /// Counts changes to whether the window can be seen, so a cover that lifts again at once is never acted on.
    private var occlusionChanges = 0

    /// Holds the frames while the window is covered, as it is by a full-screen app. Moving between desktops covers it
    /// for a moment too, and holding then would make the view jump on, so only a cover lasting a second counts.
    private func occlusionChanged() {
        occlusionChanges += 1
        guard !isVisible else {
            set(.occluded, false)
            onOcclusionChange()
            if revealing {
                revealing = false
                onReveal()
            }
            return
        }
        let change = occlusionChanges
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, occlusionChanges == change, link != nil, !isVisible else { return }
            set(.occluded, true)
            onOcclusionChange()
        }
    }

    /// Called when this wallpaper is covered or uncovered.
    var onOcclusionChange: () -> Void = {}
    /// Called once the window is up over the desktop picture and can be seen.
    var onReveal: () -> Void = {}

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
        guard !gpu.revoked else { return }
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
        // Ground still being painted in pieces, or more of it due than one frame should paint: nothing is drawn until
        // it is all there, and nothing at all once the GPU takes no more work.
        guard !gpu.revoked, !renderer.isCatchingUp else { return }
        if renderer.needsCatchUp(world: world, at: moment) {
            if CACurrentMediaTime() >= catchUpAfter { catchUp() }
            return
        }
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

    /// Draws the world as it is at `moment`, for a frame meant to be on screen at `display` time, going up at
    /// `presentAt`, or as soon as it is ready. Calls `done` once it is presented; returns whether it drew.
    @discardableResult
    private func draw(at moment: TimeInterval, showing display: TimeInterval, presentAt: TimeInterval?,
                      done: (@MainActor () -> Void)? = nil) -> Bool {
        #if DEBUG
        let asked = CACurrentMediaTime()
        #endif
        guard let drawable = view.metalLayer.nextDrawable(),
              let commands = gpu.commandBuffer() else { return false }
        #if DEBUG
        drawableWait = CACurrentMediaTime() - asked
        #endif
        let sent = gpu.cuts
        renderer.encode(world: world, at: moment, into: drawable.texture, commandBuffer: commands)
        let painted = renderer.paintedTexels
        commands.addCompletedHandler { [weak self] buffer in
            let outcome = GPUOutcome(buffer)
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome.completed {
                    self.renderer.finished(gpu: outcome.milliseconds, painted: painted)
                    self.gpu.recoverIfQuiet()
                } else {
                    // What the frame painted into the cache may not be there, so it is all painted again, a little
                    // later, as a GPU in trouble shouldn't be handed a catch-up straight away.
                    self.gpu.failed(outcome, doing: "drawing a frame", sent: sent)
                    self.catchUpAfter = CACurrentMediaTime() + 2
                    self.repaint()
                }
            }
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
        if let done {
            drawable.addPresentedHandler { _ in
                DispatchQueue.main.async { done() }
            }
        }
        if let presentAt, !presentAt.isNaN { commands.present(drawable, atTime: presentAt) } else { commands.present(drawable) }
        commands.commit()
        return true
    }

    #if DEBUG
    private lazy var stats = FrameStats(display: displayID)
    private var drawableWait = 0.0
    private var lastBirdDrawn: SIMD2<Double>?
    #endif
}
