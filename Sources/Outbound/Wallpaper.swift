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
        case user, asleep, locked, inactive, lowPower, resting
        /// Nobody can see this display: macOS says something covers all of it, or app windows hide its desktop.
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
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        })
    }

    /// Paints the first frame straight away and puts the window up once it is presented, so the desktop picture gives way
    /// to the painting itself, not to an empty window, and nothing waits for the display link. Called once the
    /// wallpaper is set up, so that frame already has the right border and scale.
    func show() {
        view.layoutSubtreeIfNeeded()
        updateCaption()
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
        // Hidden already, as under a full-screen app: held before it starts, so its frame clock never runs.
        if coveredByWindows {
            keepParting()
            set(.hidden, true)
        }
        set(.starting, false)
        revealing = true
        revealedAt = CACurrentMediaTime()
        visibilityChanged()
        onHiddenChange()
        // Up under a screen saver, it is never seen, and must stop rather than wait a second for each drawable.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealGrace) { [weak self] in self?.visibilityChanged() }
    }

    /// Up, and waiting to be seen: the window says so a moment after it goes up.
    private var revealing = false
    private var revealedAt: TimeInterval = 0
    /// How long a window just up may go unseen before it counts as hidden.
    private static let revealGrace: TimeInterval = 1

    func move(to screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        place(on: screen)
        applyScale(on: screen)
    }

    /// On battery a Retina display draws at 1.5x and lets Core Animation scale it up: almost half the pixels.
    /// The drawable and the renderer always change together, or the cache would tile across the screen.
    private func applyScale(on screen: NSScreen) {
        // A picture kept from before no longer fits the frames.
        forgetParting()
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
        forgetParting()
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
    }

    func repaint() {
        renderer.invalidate()
    }

    /// Brings the ground up to the flight while nobody can see this display, without drawing a frame: a covered window
    /// gets no drawables, and asking for one stalls for a second.
    func keepUp(at moment: TimeInterval) {
        guard let commands = gpu.queue.makeCommandBuffer() else { return }
        commands.label = "Keeping up"
        renderer.keepUp(world: world, at: moment, commandBuffer: commands)
        commands.commit()
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

    /// Draws the world as it is now, held, after it has gone back to an earlier moment, behind the lock screen. The lock
    /// screen hides the window a moment before the Mac says it is locking, so it may be hidden already: drawn even so,
    /// coming back shows this moment; given no drawable, it keeps what it showed, and coming back dissolves from that.
    func redraw() {
        let hidden = holds.contains(.hidden)
        if !hidden { forgetParting() }
        updateCaption()
        guard draw(at: world.time, showing: CACurrentMediaTime(), presentAt: nil) else { return }
        if hidden { forgetParting() }
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
        }
    }

    /// Whether macOS says any of the window can be seen. App windows over the desktop don't change it (see
    /// `coveredByWindows`), so desktop pictures keep following the desktops that are there.
    var isVisible: Bool { window.occlusionState.contains(.visible) }

    /// App windows hide this display's desktop, which macOS doesn't say for a window at the desktop's level (see
    /// `CoverWatch`).
    var coveredByWindows = false {
        didSet { if coveredByWindows != oldValue { visibilityChanged() } }
    }

    /// Stops drawing the moment nobody can see this display, and starts again the moment someone can: a hidden window
    /// gets no drawables, and asking for one stalls for a second. Just up, the window isn't seen for a moment, so for a
    /// second, until macOS first says it is, only app windows over it count.
    private func visibilityChanged() {
        guard link != nil, !holds.contains(.starting) else { return }
        let occluded = !isVisible && (!revealing || CACurrentMediaTime() - revealedAt >= Self.revealGrace)
        let hidden = occluded || coveredByWindows
        if hidden != holds.contains(.hidden) {
            if hidden { keepParting() }
            set(.hidden, hidden)
            if !hidden { comeBack() }
            onHiddenChange()
        }
        if isVisible, revealing {
            revealing = false
            onReveal()
        }
    }

    /// How far behind the flight this display draws: as far as it was hidden, when that was only a moment, so it carries
    /// on from the frame still showing instead of leaping ahead or hurrying to catch up.
    private var offset: TimeInterval = 0
    /// Just back after a moment hidden: the next frame works out `offset`.
    private var resuming = false
    /// Hidden longer than this, the view has moved on too far to carry on from, and it dissolves instead.
    private static let carryOnLimit: TimeInterval = 1

    /// Called when this wallpaper is hidden or can be seen again.
    var onHiddenChange: () -> Void = {}
    /// Called once the window is up over the desktop picture and can be seen.
    var onReveal: () -> Void = {}

    private func applyFrameRate() {
        link?.rate = framesPerSecond
    }

    // MARK: - Coming back

    /// What this display last drew: its moment, and how far a dissolve had faded then.
    private var lastFrame: (moment: TimeInterval, fade: Float)?
    /// When the bird's own layer last drew it.
    private var lastBird: TimeInterval?
    /// What this display showed when it was hidden, kept for the dissolve on coming back. The system may take it back
    /// meanwhile, while memory is short; the view then just changes.
    private var parting: (texture: MTLTexture, moment: TimeInterval)?
    /// A dissolve under way: what it fades out, and the moment of its first frame.
    private var dissolve: (texture: MTLTexture, start: TimeInterval?)?
    /// The bird was on its own layer when this display was hidden, and is painted with the landscape from the first
    /// frame back.
    private var birdLayerLeft = false
    private static let dissolveTime: TimeInterval = {
        #if DEBUG
        // OUTBOUND_DISSOLVE=3 slows the dissolve down to three seconds, to look at it closely.
        if let seconds = ProcessInfo.processInfo.environment["OUTBOUND_DISSOLVE"].flatMap(Double.init), seconds > 0 {
            return seconds
        }
        #endif
        return 0.5
    }()

    /// Paints again what the window shows as this display is hidden: its last frame, with any dissolve as far as it had
    /// got and the bird even if it flew on a layer of its own, painting no ground that was only waiting.
    private func keepParting() {
        defer { dissolve = nil }
        parting = nil
        let size = stillSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShaderLibrary.viewFormat,
                                                                  width: Int(size.width), height: Int(size.height),
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let last = lastFrame, size.width > 0, size.height > 0,
              let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commands = gpu.queue.makeCommandBuffer() else { return }
        texture.label = "Parting"
        commands.label = "Parting"
        renderer.encode(world: world, at: last.moment, into: texture, commandBuffer: commands,
                        overlay: dissolve.map { ($0.texture, last.fade) }, birdAt: renderer.drawsBird ? nil : lastBird,
                        paintsWaiting: false)
        let kept = ObjectIdentifier(texture)
        commands.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                // Kept while hidden, but the system may take it back while memory is short.
                guard let self, self.holds.contains(.hidden), let parting = self.parting,
                      ObjectIdentifier(parting.texture) == kept else { return }
                parting.texture.setPurgeableState(.volatile)
            }
        }
        commands.commit()
        parting = (texture, last.moment)
        foldBird()
    }

    /// Paints the bird with the landscape from the next frame drawn, its own layer showing it, still, until then.
    private func foldBird() {
        guard !renderer.drawsBird else { return }
        renderer.drawsBird = true
        birdHandOvers += 1
        birdLink?.invalidate()
        birdLink = nil
        birdLayerLeft = true
    }

    /// Coming back: hidden only a moment, it carries on from what it showed, at the flight's own speed and that little
    /// behind it, never hurrying to catch up. Hidden while the flight moved on further, its first frames dissolve from
    /// what it showed to where the flight has got to.
    private func comeBack() {
        resuming = false
        guard let parting else { return }
        self.parting = nil
        let gap = world.renderTime(for: CACurrentMediaTime()) - parting.moment
        if gap >= 0, gap <= Self.carryOnLimit {
            resuming = true
            return
        }
        offset = 0
        // Back before where it left off, as the lock screen can leave it; or the picture was taken back by the system
        // meanwhile, or is no longer the size of a frame: the view just changes.
        guard abs(gap) >= 0.25, parting.texture.setPurgeableState(.nonVolatile) != .empty,
              CGSize(width: parting.texture.width, height: parting.texture.height) == stillSize else { return }
        dissolve = (parting.texture, nil)
        Log.display.info("Display \(self.displayID) dissolving from \(String(format: "%.1f", gap), privacy: .public) s back")
    }

    private func forgetParting() {
        parting = nil
        dissolve = nil
        offset = 0
    }

    /// How much of the picture kept from before this frame shows, from all of it to none, eased at both ends and timed
    /// in the world's time, so a pause midway carries on from the same point.
    private func dissolveFade(at moment: TimeInterval) -> (texture: MTLTexture, fade: Float)? {
        guard let dissolve else { return nil }
        let start = dissolve.start ?? moment
        if dissolve.start == nil { self.dissolve?.start = moment }
        let progress = min(max((moment - start) / Self.dissolveTime, 0), 1)
        let fade = Float(1 - Easing.smoothstep(progress))
        guard fade > 0 else {
            self.dissolve = nil
            return nil
        }
        return (dissolve.texture, fade)
    }

    /// Takes the bird off its own layer once the frame painting it with the landscape is on screen.
    private func hideBirdLayer(at presentTime: TimeInterval) {
        birdHandOvers += 1
        let handOver = birdHandOvers
        DispatchQueue.main.asyncAfter(deadline: .now() + max(presentTime - CACurrentMediaTime(), 0)) { [weak self] in
            guard let self, birdHandOvers == handOver else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            birdView.isHidden = true
            CATransaction.commit()
        }
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
                drawBird(at: world.renderTime(for: presentTime + refresh) - offset)
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
        lastBird = time
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
        // On macOS 13 a tick on its way to the main thread can arrive just after the clock stopped.
        guard birdLink != nil, link?.isPaused == false else { return }
        world.advance(to: tick.targetTimestamp)
        drawBird(at: world.renderTime(for: tick.targetTimestamp) - offset)
    }

    private func tick(_ tick: FrameClock.Tick) {
        // On macOS 13 a tick on its way to the main thread can arrive just after the clock stopped, as the display
        // was hidden: drawing then would wait a second for a drawable that never comes.
        guard link?.isPaused == false else { return }
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
        if resuming, let last = lastFrame {
            // Back after a moment hidden: carry on one frame from the one the window still shows.
            offset = min(max(world.renderTime(for: onScreen) - Double(1 / framesPerSecond) - last.moment, 0), 1)
            Log.display.info("Display \(self.displayID) carrying on \(Int(self.offset * 1000), privacy: .public) ms behind")
        }
        resuming = false
        let moment = world.renderTime(for: onScreen) - offset
        handOverBird(at: moment, presenting: presentTime)
        if birdLayerLeft {
            birdLayerLeft = false
            // Back from hidden, the landscape paints the bird; unless it went straight back to its layer, the layer
            // still showing it from before goes as this frame goes up.
            if renderer.drawsBird { hideBirdLayer(at: presentTime) }
        }
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
              let commands = gpu.queue.makeCommandBuffer() else { return false }
        #if DEBUG
        drawableWait = CACurrentMediaTime() - asked
        #endif
        let overlay = dissolveFade(at: moment)
        renderer.encode(world: world, at: moment, into: drawable.texture, commandBuffer: commands, overlay: overlay)
        lastFrame = (moment, overlay?.fade ?? 0)
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
