import AppKit
import OutboundCore

/// Keeps one wallpaper on every display, and pauses them all when nobody can see them.
@MainActor
final class DisplayManager {
    let world: World
    let gpu: GPU
    let power: PowerMonitor
    private(set) var wallpapers: [CGDirectDisplayID: Wallpaper] = [:]
    private var globalHolds: Set<Wallpaper.Hold> = []
    /// Every display's desktop is hidden, by full-screen apps or other windows say, and Pause When Hidden is on. Nobody
    /// can see the flight, so it waits, as it does while the Mac is locked: coming back shows the same place, with the
    /// ground each display cached still good, rather than the whole view repainted at once.
    private var pausedHidden = false {
        didSet {
            guard pausedHidden != oldValue else { return }
            wallpapers.values.forEach { $0.set(.hidden, pausedHidden) }
            holdWorld()
            Log.display.info("\(self.pausedHidden ? "Every display is hidden: holding still" : "Carrying on", privacy: .public)")
        }
    }
    /// Hold the flight while every display's desktop is hidden. Off, it flies on whether anyone can see it or not.
    var pausesWhenHidden = false {
        didSet {
            guard pausesWhenHidden != oldValue else { return }
            watchCover()
            checkOcclusion()
        }
    }
    private(set) var tier = PowerTier.choose(PowerState())
    private var started = false
    /// Wallpapers only exist while running; before Outbound is unlocked it is not.
    var running = false {
        didSet { if started && running != oldValue { sync() } }
    }
    /// A line shown under every caption.
    var note: String? {
        didSet { wallpapers.values.forEach { $0.note = note } }
    }
    /// Whether the paintings have their pale border.
    var paperEdge = true {
        didSet { wallpapers.values.forEach { $0.paperEdge = paperEdge } }
    }

    init(world: World, gpu: GPU, power: PowerMonitor) {
        self.world = world
        self.gpu = gpu
        self.power = power
    }

    func start() {
        guard !started else { return }
        started = true
        // Not documented, but long-standing and what every screen-aware app listens to. Listened for before asking,
        // so an unlock while the wallpapers start up is never missed.
        let distributed = DistributedNotificationCenter.default()
        for (name, on) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lockedAtLaunch = false
                    self?.set(.locked, on)
                    self?.onLockChange(on)
                }
            }
        }
        // Launched while the Mac is locked, say to install an update, nothing says so later.
        if Self.screenIsLocked {
            lockedAtLaunch = true
            set(.locked, true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.holdsForFirstFrames = false
            self?.holdWorld()
        }
        cover.onChange = { [weak self] id, covered in
            Log.display.info("Display \(id) \(covered ? "covered by windows" : "no longer covered by windows", privacy: .public)")
            self?.wallpapers[id]?.coveredByWindows = covered
        }
        sync()
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let holds: [(Notification.Name, Wallpaper.Hold, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .asleep, true),
            (NSWorkspace.screensDidWakeNotification, .asleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactive, false)
        ]
        for (name, hold, on) in holds {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(hold, on) }
            }
        }

        gpu.shaders.onReload = { [weak self] in self?.repaint() }
        rest.onChange = { [weak self] resting in
            self?.set(.resting, resting)
            Log.power.info("\(resting ? "Resting: nobody is around" : "Awake", privacy: .public)")
        }
        rest.start()
        power.onChange = { [weak self] _ in self?.applyPower() }
        applyPower()
    }

    private func applyPower() {
        tier = PowerTier.choose(power.state)
        set(.lowPower, tier.frozen)
        wallpapers.values.forEach {
            $0.halfRateClouds = tier.halfRateClouds
            $0.economical = power.state.onBattery
        }
        refreshRates()
    }

    let rest = RestMonitor()
    /// Tells when app windows hide a display's desktop, which macOS doesn't say for a window at the desktop's level.
    let cover = CoverWatch()

    /// Nobody can see any display: they are asleep, or another user has the Mac.
    var isAsleep: Bool {
        !globalHolds.isDisjoint(with: [.asleep, .inactive])
    }

    /// Nobody is watching: the screens are asleep or locked, another user has the Mac, or it has been left alone.
    var isQuiet: Bool {
        !globalHolds.isDisjoint(with: [.asleep, .locked, .inactive, .resting])
    }

    /// The Mac is locked.
    var isLocked: Bool {
        globalHolds.contains(.locked)
    }

    /// The wallpapers up and in view, not covered by a full-screen app.
    var wallpapersInView: [Wallpaper] {
        wallpapers.values.filter { $0.holds.isDisjoint(with: [.occluded, .starting]) && $0.isVisible }
    }

    /// Displays whose wallpaper is covered, as it is by a full-screen app, even if only for a moment so far.
    var occludedDisplays: Set<CGDirectDisplayID> {
        Set(wallpapers.values.filter {
            $0.holds.contains(.occluded) || (!$0.holds.contains(.starting) && !$0.isVisible)
        }.map(\.displayID))
    }

    static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Called as a quiet moment begins, a good time to install an update.
    var onQuiet: () -> Void = {}

    /// Called as the Mac locks (true) and unlocks (false).
    var onLockChange: (Bool) -> Void = { _ in }

    /// Called as a wallpaper comes up over the desktop picture.
    var onReveal: () -> Void = {}

    var isPaused: Bool {
        get { globalHolds.contains(.user) }
        set { set(.user, newValue) }
    }

    func set(_ hold: Wallpaper.Hold, _ on: Bool) {
        if on { globalHolds.insert(hold) } else { globalHolds.remove(hold) }
        // Windows may have moved while nothing was drawn, so they are read again before any display starts once more.
        watchCover()
        wallpapers.values.forEach { $0.set(hold, on) }
        holdWorld()
        if on, [.asleep, .locked, .inactive, .resting].contains(hold) { onQuiet() }
    }

    /// The flight waits while anything holds every display, and as Outbound opens while a display's first frame is still
    /// being painted, so it sets off from the moment that frame shows, gathering speed, rather than having flown on
    /// unseen. A display added later never holds the others, nor does a first frame that takes over ten seconds.
    private func holdWorld() {
        let opening = holdsForFirstFrames && wallpapers.values.contains { $0.holds.contains(.starting) }
        world.hold(!globalHolds.isEmpty || pausedHidden || opening)
    }

    private var holdsForFirstFrames = true

    private func firstFramesShown() {
        guard holdsForFirstFrames, !wallpapers.values.contains(where: { $0.holds.contains(.starting) }) else {
            holdWorld()
            return
        }
        holdsForFirstFrames = false
        holdWorld()
    }

    /// The Mac was locked as Outbound opened, as it is when an update installs, and only an unlock it is told of lets
    /// go of that. Should the session have said locked when it wasn't, say at login, nothing would ever let go, so
    /// it is asked again now and then.
    private var lockedAtLaunch = false

    func recheckLock() {
        guard lockedAtLaunch, globalHolds.contains(.locked), !Self.screenIsLocked else { return }
        lockedAtLaunch = false
        Log.display.info("Not locked after all: carrying on")
        set(.locked, false)
        onLockChange(false)
    }

    /// Shows a change to the view while the flight is held, which no frame would show until it carries on: each
    /// wallpaper that is up paints its ground afresh and draws once. A change to the frame pass alone, like the border,
    /// only needs `redrawHeld`.
    func repaintHeld() {
        for wallpaper in wallpapers.values {
            wallpaper.repaint()
            // One still painting its first frame paints it afresh by itself.
            if !wallpaper.holds.contains(.starting) { wallpaper.redraw() }
        }
    }

    func redrawHeld() {
        for wallpaper in wallpapers.values where !wallpaper.holds.contains(.starting) { wallpaper.redraw() }
    }

    /// What holds the displays still, by name, for the feedback page.
    var holdNames: [String] {
        Set(wallpapers.values.flatMap(\.holds)).union(globalHolds).map { "\($0)" }.sorted()
    }

    /// Reads which desktops app windows cover, only with Pause When Hidden on, and only while anything is drawn: not
    /// while the Mac is locked, asleep, resting or paused.
    private func watchCover() {
        guard pausesWhenHidden else {
            cover.stop()
            cover.displays = []
            wallpapers.values.forEach { $0.coveredByWindows = false }
            return
        }
        cover.displays = Array(wallpapers.keys)
        if running, globalHolds.isEmpty { cover.start() } else { cover.stop() }
    }

    func repaint() {
        world.repaint()
    }

    private func sync() {
        // Before any new wallpaper paints: its first frame bakes the river into the ground it keeps.
        world.desktop = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if let main = NSScreen.screens.first {
            world.home = main.frame
            world.centreRiver(on: main.frame)
        }
        var seen = Set<CGDirectDisplayID>()
        var added: [Wallpaper] = []
        for screen in NSScreen.screens where running {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let wallpaper = wallpapers[id] {
                wallpaper.move(to: screen)
            } else {
                let wallpaper = Wallpaper(screen: screen, displayID: id, world: world, gpu: gpu)
                wallpaper.note = note
                wallpaper.paperEdge = paperEdge
                wallpaper.economical = power.state.onBattery
                globalHolds.forEach { wallpaper.set($0, true) }
                if pausedHidden { wallpaper.set(.hidden, true) }
                wallpaper.coveredByWindows = cover.covered.contains(id)
                wallpaper.onOcclusionChange = { [weak self] in self?.checkOcclusion() }
                wallpaper.onStarted = { [weak self] in self?.firstFramesShown() }
                // Once every display's is up, so the first paintings are of one moment.
                wallpaper.onReveal = { [weak self] in
                    guard let self,
                          wallpapers.values.allSatisfy({ !$0.holds.contains(.starting) && $0.isVisible }) else { return }
                    onReveal()
                }
                wallpapers[id] = wallpaper
                added.append(wallpaper)
                Log.display.info("Added display \(id) \(String(describing: screen.frame), privacy: .public) @\(screen.backingScaleFactor)x")
            }
        }
        for (id, wallpaper) in wallpapers where !seen.contains(id) {
            wallpaper.close()
            wallpapers[id] = nil
            Log.display.info("Removed display \(id)")
        }
        watchCover()
        checkOcclusion()
        refreshRates()
        holdWorld()
        added.forEach { $0.show() }
    }

    private func checkOcclusion() {
        pausedHidden = pausesWhenHidden && !wallpapers.isEmpty
            && wallpapers.values.allSatisfy { $0.holds.contains(.occluded) || $0.coveredByWindows }
    }

    /// The tier's frame rates, as each display can show them evenly.
    private func refreshRates() {
        guard tier.framesPerSecond > 0 else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let wallpaper = wallpapers[id] else { continue }
            let fastest = screen.minimumRefreshInterval > 0 ? 1 / screen.minimumRefreshInterval
                : Double(screen.maximumFramesPerSecond)
            // Only the built-in panel paces a desktop window at any rate in its range; external adaptive-sync
            // panels vary their refresh only for full-screen apps, so a window behind everything gets a fixed rate.
            let ranged = screen.maximumRefreshInterval > screen.minimumRefreshInterval + 0.0005
            let slowest = CGDisplayIsBuiltin(id) != 0 && ranged ? 1 / screen.maximumRefreshInterval : nil
            wallpaper.framesPerSecond = Float(FramePacing.rate(target: tier.framesPerSecond, fastest: fastest,
                                                               slowest: slowest))
            wallpaper.birdFramesPerSecond = Float(FramePacing.rate(target: tier.birdFramesPerSecond, fastest: fastest,
                                                                   slowest: slowest))
            wallpaper.halfRateClouds = tier.halfRateClouds
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
