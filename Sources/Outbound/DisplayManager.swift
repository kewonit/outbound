import AppKit
import OutboundCore

/// Keeps one wallpaper on every display, and stops drawing on any that nobody can see.
@MainActor
final class DisplayManager {
    let world: World
    let gpu: GPU
    let power: PowerMonitor
    private(set) var wallpapers: [CGDirectDisplayID: Wallpaper] = [:]
    private var globalHolds: Set<Wallpaper.Hold> = []
    /// Nobody can see any display: full-screen apps or other windows hide every desktop. With Pause When Hidden on, the
    /// flight waits from that moment, as it does while the Mac is locked, and coming back shows the same place.
    /// Otherwise it flies on unseen, and coming back dissolves to where it has got to.
    private var everyHidden = false {
        didSet {
            guard everyHidden != oldValue else { return }
            let line = !everyHidden ? "A display is in view again"
                : pausesWhenHidden ? "Every display is hidden: holding still" : "Every display is hidden: flying on unseen"
            Log.display.info("\(line, privacy: .public)")
        }
    }
    /// Hold the flight while every display is hidden.
    var pausesWhenHidden = false {
        didSet { if pausesWhenHidden != oldValue { holdWorld() } }
    }
    /// When the flight, held while it was hidden or locked, goes on even though nothing is in view yet.
    private var releaseAt: TimeInterval?
    /// Brings each covered display's ground up to the flight every couple of seconds while it flies on unseen.
    private var upkeep: Timer?
    #if DEBUG
    private var keptUp: TimeInterval?
    #endif
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
                    self?.set(.locked, on)
                    self?.onLockChange(on)
                }
            }
        }
        // Launched while the Mac is locked, say to install an update, nothing says so later.
        if Self.screenIsLocked { set(.locked, true) }
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
        cover.onChange = { [weak self] id, covered in
            Log.display.info("Display \(id) \(covered ? "covered by windows" : "no longer covered by windows", privacy: .public)")
            self?.wallpapers[id]?.coveredByWindows = covered
        }
        watchCover()
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

    /// The wallpapers up and in view as macOS sees them, for the desktop pictures. A desktop under app windows is
    /// still a desktop there, whose picture the lock screen shows, so it counts.
    var wallpapersInView: [Wallpaper] {
        wallpapers.values.filter { !$0.holds.contains(.starting) && $0.isVisible }
    }

    /// Displays whose wallpaper macOS says is out of view, as it is under a screen saver.
    var occludedDisplays: Set<CGDirectDisplayID> {
        Set(wallpapers.values.filter { !$0.holds.contains(.starting) && !$0.isVisible }.map(\.displayID))
    }

    private static var screenIsLocked: Bool {
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

    /// Holds the flight while anything holds every display (asleep, locked, paused and the like), or while every
    /// display is covered with Pause When Hidden on. A hold lifting while every display is still covered, as the Mac
    /// unlocks behind the lock screen, keeps the flight where it is until a display is in view, for two seconds at most:
    /// it then carries on from the moment the lock screen showed rather than a little past it.
    private func holdWorld() {
        let held = !globalHolds.isEmpty || (everyHidden && pausesWhenHidden)
        if !held, everyHidden, world.isHeld {
            if releaseAt == nil {
                let at = CACurrentMediaTime() + 2
                releaseAt = at
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, releaseAt == at else { return }
                    releaseAt = nil
                    world.hold(!globalHolds.isEmpty || (everyHidden && pausesWhenHidden))
                    updateUpkeep()
                }
            }
        } else {
            releaseAt = nil
            world.hold(held)
        }
        updateUpkeep()
    }

    /// Reads which desktops app windows cover while anything is drawn, and not while the Mac is locked, asleep,
    /// resting or paused.
    private func watchCover() {
        cover.displays = Array(wallpapers.keys)
        if running, globalHolds.isEmpty { cover.start() } else { cover.stop() }
    }

    /// Wallpapers nobody can see while the flight goes on: hidden, and held by nothing else.
    private var unseen: [Wallpaper] {
        wallpapers.values.filter { $0.holds == [.hidden] }
    }

    /// Keeps the ground of every display nobody can see up with the flight while it goes on, so coming back to one
    /// paints a strip rather than the whole view at once. Every couple of seconds is plenty: the flight reveals a few
    /// dozen rows of ground a second.
    private func updateUpkeep() {
        let wanted = running && !world.isHeld && !unseen.isEmpty
        guard wanted != (upkeep != nil) else { return }
        if wanted {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepUp() }
            }
            timer.tolerance = 0.5
            // The common modes, so it keeps up while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            upkeep = timer
            Log.display.info("Keeping covered displays up with the flight")
        } else {
            upkeep?.invalidate()
            upkeep = nil
            #if DEBUG
            keptUp = nil
            #endif
            Log.display.info("No longer keeping covered displays up")
        }
    }

    private func keepUp() {
        let now = CACurrentMediaTime()
        #if DEBUG
        // App Nap can hold the timer back while every window is covered; the first frame back then paints more.
        if let keptUp, now - keptUp > 4 {
            Log.display.info("Kept up \(String(format: "%.1f", now - keptUp), privacy: .public) s after the last time")
        }
        keptUp = now
        #endif
        // Nothing to do when a display in view has already taken the flight further.
        world.advance(to: now)
        let moment = world.renderTime(for: now)
        unseen.forEach { $0.keepUp(at: moment) }
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
                wallpaper.coveredByWindows = cover.covered.contains(id)
                wallpaper.onHiddenChange = { [weak self] in self?.checkHidden() }
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
        checkHidden()
        refreshRates()
        added.forEach { $0.show() }
    }

    /// Holds or releases the flight when every display becomes hidden or one comes back into view; otherwise only which
    /// displays to keep up has changed.
    private func checkHidden() {
        let every = !wallpapers.isEmpty && wallpapers.values.allSatisfy { $0.holds.contains(.hidden) }
        if every != everyHidden {
            everyHidden = every
            holdWorld()
        } else {
            updateUpkeep()
        }
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
