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
    /// Every display's wallpaper is covered, by full-screen apps say. Nobody can see the flight, so it waits, as it
    /// does while the Mac is locked: coming back shows the same place, with the ground each display cached still good,
    /// rather than the whole view repainted at once.
    private var everyOccluded = false {
        didSet {
            guard everyOccluded != oldValue else { return }
            world.hold(!globalHolds.isEmpty || everyOccluded)
            Log.display.info("\(self.everyOccluded ? "Every display is covered: holding still" : "A display is in view again", privacy: .public)")
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
        // Not documented, but long-standing and what every screen-aware app listens to.
        let distributed = DistributedNotificationCenter.default()
        for (name, on) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.set(.locked, on)
                    self?.onLockChange(on)
                }
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
        wallpapers.values.filter { $0.holds.isDisjoint(with: [.occluded, .starting]) }
    }

    /// Displays whose wallpaper is covered, as it is by a full-screen app.
    var occludedDisplays: Set<CGDirectDisplayID> {
        Set(wallpapers.values.filter { $0.holds.contains(.occluded) }.map(\.displayID))
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
        wallpapers.values.forEach { $0.set(hold, on) }
        world.hold(!globalHolds.isEmpty || everyOccluded)
        if on, [.asleep, .locked, .inactive, .resting].contains(hold) { onQuiet() }
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
                wallpaper.onOcclusionChange = { [weak self] in self?.checkOcclusion() }
                wallpaper.onReveal = { [weak self] in self?.onReveal() }
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
        checkOcclusion()
        refreshRates()
        added.forEach { $0.show() }
    }

    private func checkOcclusion() {
        everyOccluded = !wallpapers.isEmpty && wallpapers.values.allSatisfy { $0.holds.contains(.occluded) }
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
