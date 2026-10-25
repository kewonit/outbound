import AppKit
import OutboundCore

/// Keeps one wallpaper on every display, and pauses them all when nobody can see them.
@MainActor
final class DisplayManager {
    let world: World
    let gpu: GPU
    let power: PowerMonitor
    private var wallpapers: [CGDirectDisplayID: Wallpaper] = [:]
    private var globalHolds: Set<Wallpaper.Hold> = []
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

    init(world: World, gpu: GPU, power: PowerMonitor) {
        self.world = world
        self.gpu = gpu
        self.power = power
    }

    func start() {
        guard !started else { return }
        started = true
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
                MainActor.assumeIsolated { self?.set(.locked, on) }
            }
        }

        gpu.shaders.onReload = { [weak self] in self?.repaint() }
        world.onChasingChange = { [weak self] chasing in self?.power.birdEngaged = chasing }
        power.onChange = { [weak self] _ in self?.applyPower() }
        applyPower()
    }

    private func applyPower() {
        tier = PowerTier.choose(power.state)
        set(.lowPower, tier.frozen)
        wallpapers.values.forEach { $0.halfRateClouds = tier.halfRateClouds }
        refreshRates()
    }

    var isPaused: Bool {
        get { globalHolds.contains(.user) }
        set { set(.user, newValue) }
    }

    func set(_ hold: Wallpaper.Hold, _ on: Bool) {
        if on { globalHolds.insert(hold) } else { globalHolds.remove(hold) }
        wallpapers.values.forEach { $0.set(hold, on) }
    }

    func repaint() {
        world.repaint()
    }

    private func sync() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens where running {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let wallpaper = wallpapers[id] {
                wallpaper.move(to: screen)
            } else {
                let wallpaper = Wallpaper(screen: screen, displayID: id, world: world, gpu: gpu)
                wallpaper.note = note
                globalHolds.forEach { wallpaper.set($0, true) }
                wallpapers[id] = wallpaper
                Log.display.info("Added display \(id) \(String(describing: screen.frame), privacy: .public) @\(screen.backingScaleFactor)x")
            }
        }
        for (id, wallpaper) in wallpapers where !seen.contains(id) {
            wallpaper.close()
            wallpapers[id] = nil
            Log.display.info("Removed display \(id)")
        }
        world.desktop = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if let main = NSScreen.screens.first { world.centreRiver(on: main.frame) }
        refreshRates()
    }

    /// The tier's frame rate, or the nearest below it that divides the display's refresh evenly.
    private func refreshRates() {
        guard tier.framesPerSecond > 0 else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let wallpaper = wallpapers[id] else { continue }
            let refresh = Double(screen.maximumFramesPerSecond)
            wallpaper.framesPerSecond = Float(FramePacing.rate(target: tier.framesPerSecond, refresh: refresh))
            wallpaper.halfRateClouds = tier.halfRateClouds
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
