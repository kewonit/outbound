import AppKit
import Combine
import OutboundCore
import SwiftUI

@main
@MainActor
enum OutboundApp {
    static let delegate = AppDelegate()

    static func main() {
        let arguments = CommandLine.arguments
        if Exporter.handles(arguments) { exit(Exporter.run(arguments)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var displays: DisplayManager!
    private var stills: StillWriter!
    private let preferences = Preferences()
    private let license = LicenseController()
    private var activation: ActivationWindow?
    private var gpu: GPU!
    private var updates: Updates!
    private var licenseTimer: Timer?
    private var settingsWindow: NSWindow?
    private var stillTimer: Timer?
    private var stillLeg = -1
    private var stillTaken = Date.distantPast
    private var stillsWereOn = false
    private var signals: [DispatchSourceSignal] = []
    private var preferencesChanged: AnyCancellable?
    /// Links from the thank-you page that arrived before launch finished.
    private var earlyLinks: [ActivationLink] = []

    private var world: World { displays.world }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        // `kill` or `killall Outbound` quits properly too, so the user's own desktop picture comes back.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        installMainMenu()
        do {
            gpu = try GPU()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Outbound could not start its renderer."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let place = Place.named(preferences.lastPlace) ?? .first
        let world = World(place: place, time: CACurrentMediaTime(), light: preferences.light)
        displays = DisplayManager(world: world, gpu: gpu, power: PowerMonitor(batteryMode: preferences.batteryMode))
        stills = StillWriter(gpu: gpu)
        updates = Updates()
        updates.isQuiet = { [weak self] in self?.displays.isQuiet ?? false }
        displays.onQuiet = { [weak self] in self?.updates.installIfQuiet() }
        stillsWereOn = preferences.matchingStill
        applyPreferences()
        if !LicenseController.isGated { displays.note = "Development build" }
        displays.running = license.unlocks
        displays.start()
        // A painting left behind by a crash or an older version goes back to the user's own picture.
        stills.restore()
        displays.onLockChange = { [weak self] locked in self?.lockChanged(locked) }
        // macOS keeps a picture for each desktop, so check each one as it comes into view, once it has settled.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.stills.restore() }
            }
        }
        installStatusItem()
        observePreferences()

        // Keep a painting of the view ready for the lock screen, checking twice a minute for a new place.
        stillTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStill(force: false) }
        }
        refreshStill(force: true)

        license.onChange = { [weak self] unlocked in self?.licenseChanged(unlocked) }
        if !license.unlocks {
            showActivation()
            license.resumePurchase()
        }
        Task { await license.refresh() }
        licenseTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.license.refresh() }
        }
        // Back from the browser after paying: ask about the purchase now rather than at the next tick.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.license.checkPurchaseNow() }
        }
        earlyLinks.forEach(handle)
        earlyLinks = []
        #if DEBUG
        if ProcessInfo.processInfo.environment["OUTBOUND_EXERCISE"] != nil { exercise() }
        #endif
    }

    /// OUTBOUND_MEASURE=1 or OUTBOUND_EXERCISE=1 keeps it flying for the frame statistics in development builds:
    /// nobody touches the Mac meanwhile, so it must not rest.
    private var measuring: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["OUTBOUND_MEASURE"] != nil || environment["OUTBOUND_EXERCISE"] != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// OUTBOUND_EXERCISE=1 brings on the heavy moments while the frame statistics run: the light moving on (a repaint
    /// wave), a lock-screen still and a Fly To, twenty seconds apart after twenty-five seconds of plain flying, then
    /// the bird chasing a pretend cursor for fifteen seconds and gliding off again.
    private func exercise() {
        let moments: [(TimeInterval, String, () -> Void)] = [
            (25, "repaint wave", { [weak self] in self?.world.repaint() }),
            (45, "still", { [weak self] in guard let self else { return }; stills.prepare(world: world) }),
            (65, "Fly To", { [weak self] in
                guard let self else { return }
                let here = world.journey.leg(at: world.camera.y).place
                let next = Place.all[((Place.all.firstIndex { $0.id == here.id } ?? 0) + 1) % Place.all.count]
                fly(to: next)
            }),
            (85, "the bird chases", { [weak self] in
                guard let self else { return }
                let home = world.home, start = CACurrentMediaTime()
                world.isDesktop = { _ in true }
                world.pointer = {
                    let t = CACurrentMediaTime() - start
                    return CGPoint(x: home.midX + cos(t * 1.3) * home.width * 0.3, y: home.midY + sin(t * 1.7) * home.height * 0.3)
                }
            }),
            (100, "the bird glides", { [weak self] in
                self?.world.pointer = { NSEvent.mouseLocation }
                self?.world.isDesktop = { World.desktopIsUnder($0) }
            }),
        ]
        for (delay, name, action) in moments {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Log.render.info("Exercise: \(name, privacy: .public)")
                action()
            }
        }
    }
    #endif

    /// The painting is the desktop picture only while the Mac is locked, so it always comes off the desktop it
    /// went on: nobody can move to another one in between.
    private func lockChanged(_ locked: Bool) {
        if locked, preferences.matchingStill, license.unlocks {
            stills.show()
        } else if !locked {
            stills.restore()
        }
    }

    private func licenseChanged(_ unlocked: Bool) {
        displays.running = unlocked
        if unlocked {
            activation?.finish()
            refreshStill(force: true)
        } else {
            stills.restore()
            showActivation()
        }
    }

    private func showActivation() {
        if activation == nil {
            let window = ActivationWindow(license: license, world: world, gpu: gpu)
            window.onDone = { [weak self] in self?.activation = nil }
            activation = window
        }
        activation?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard displays != nil else { return }
        preferences.lastPlace = world.journey.leg(at: world.camera.y).place.id
        // Leave the desktop as the user had it before Outbound.
        stills.restore()
    }

    // MARK: - Links from the thank-you page

    func application(_ application: NSApplication, open urls: [URL]) {
        // Any web page can open these, so only the exact activation link is acted on.
        guard let link = urls.lazy.compactMap({ ActivationLink($0) }).last else {
            Log.license.info("Ignored a link that isn't an activation link")
            return
        }
        if displays == nil {
            earlyLinks.append(link)
        } else {
            handle(link)
        }
    }

    private func handle(_ link: ActivationLink) {
        let wasUnlocked = license.unlocks
        if !wasUnlocked { showActivation() }
        Task {
            let result = await license.claim(link.checkout) { email in
                await Notice.show("Use your new key?",
                                  detail: "Outbound is already unlocked here\(email.map { " with another key. The new one was bought with \($0)" } ?? "").",
                                  buttons: ["Use New Key", "Keep Current"]) == 0
            }
            Log.license.info("Activation link: \(String(describing: result), privacy: .public)")
            guard wasUnlocked || result == .alreadyActive else { return }
            switch result {
            case .alreadyActive: await Notice.show("Outbound is already unlocked.", detail: "")
            case .activated: await Notice.show("Outbound now uses your new key.", detail: "")
            case .failed: await Notice.show("That purchase didn't unlock Outbound.", detail: license.message ?? "")
            case .waiting: await Notice.show("Still processing your purchase.", detail: "Try again in a minute.")
            case .declined: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard displays != nil else { return false }
        if license.unlocks { openSettings() } else { showActivation() }
        return false
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }

    // MARK: - Preferences

    private func observePreferences() {
        // Told just before a preference changes, so applied once it has.
        preferencesChanged = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }
    }

    private func applyPreferences() {
        let journey = world.journey
        if world.light != preferences.light { world.light = preferences.light }
        if journey.followsCalendar != preferences.followsCalendar {
            journey.followsCalendar = preferences.followsCalendar
            journey.refreshSeasons()
            world.repaint()
        }
        if journey.speed != preferences.pace.speed { journey.setSpeed(preferences.pace.speed, at: world.time) }
        journey.staysPut = preferences.stay == .forever
        if preferences.stay != .forever { journey.legLength = Double(preferences.stay.rawValue) * 60 * preferences.pace.speed }
        displays.power.batteryMode = preferences.batteryMode
        displays.rest.after = preferences.restsWhenAway && !measuring ? 300 : nil
        let edgeChanged = displays.paperEdge != preferences.paperEdge
        displays.paperEdge = preferences.paperEdge
        if stills != nil {
            stills.paperEdge = preferences.paperEdge
            if edgeChanged { refreshStill(force: true) }
        }
        if stills != nil && preferences.matchingStill != stillsWereOn {
            if preferences.matchingStill { refreshStill(force: true) } else { stills.restore() }
        }
        stillsWereOn = preferences.matchingStill
    }

    private func refreshStill(force: Bool) {
        guard preferences.matchingStill, license.unlocks, !displays.isAsleep else { return }
        let leg = world.journey.leg(at: world.camera.y).index
        guard force || leg != stillLeg || Date.now.timeIntervalSince(stillTaken) > 600 else { return }
        stillLeg = leg
        stillTaken = .now
        stills.prepare(world: world)
    }

    // MARK: - Menu

    /// Outbound shows no menu bar, but its windows still need the usual shortcuts, and they come from the main
    /// menu: without an Edit menu, Command-V does nothing in the key field.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for menu in [app, edit, window] {
            main.addItem(submenu(menu.title, menu))
        }
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = .outboundGull
        let menu = NSMenu()
        menu.delegate = self
        // Items say for themselves whether they can be used, as Check for Updates does in development builds.
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard license.unlocks else {
            let unlock = NSMenuItem(title: "Unlock Outbound…", action: #selector(openActivation), keyEquivalent: "")
            unlock.target = self
            menu.addItem(unlock)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return
        }
        let leg = world.journey.leg(at: world.camera.y)
        let here = NSMenuItem(title: leg.place.name, action: nil, keyEquivalent: "")
        here.attributedTitle = NSAttributedString(string: leg.place.name,
                                                  attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        here.isEnabled = false
        menu.addItem(here)
        let season = NSMenuItem(title: leg.season.line, action: nil, keyEquivalent: "")
        season.isEnabled = false
        menu.addItem(season)
        menu.addItem(.separator())

        let places = NSMenu()
        func destination(_ place: Place) -> NSMenuItem {
            let item = NSMenuItem(title: place.name, action: #selector(fly(_:)), keyEquivalent: "")
            item.representedObject = place.id
            item.target = self
            item.state = place.id == leg.place.id ? .on : .off
            return item
        }
        Place.all.forEach { places.addItem(destination($0)) }
        if !Place.extended.isEmpty {
            places.addItem(.separator())
            let heading = NSMenuItem(title: "Extended Places", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            places.addItem(heading)
            Place.extended.forEach { places.addItem(destination($0)) }
        }
        menu.addItem(submenu("Fly To", places))
        let pause = NSMenuItem(title: displays.isPaused ? "Resume" : "Pause", action: #selector(togglePause),
                               keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())

        // How the painting looks.
        let preferences = preferences
        menu.addItem(choices("Light", World.Light.allCases.map { ($0.title, $0) }, current: preferences.light) {
            preferences.light = $0
        })
        menu.addItem(choices("Seasons", [("What is growing there today", true), ("Each place at its best", false)],
                             current: preferences.followsCalendar) { preferences.followsCalendar = $0 })
        let border = NSMenuItem(title: "Painted Border", action: #selector(toggleBorder), keyEquivalent: "")
        border.target = self
        border.state = preferences.paperEdge ? .on : .off
        menu.addItem(border)
        menu.addItem(.separator())

        // How it flies.
        menu.addItem(choices("Pace", Preferences.Pace.allCases.map { ($0.title, $0) }, current: preferences.pace) {
            preferences.pace = $0
        })
        menu.addItem(choices("Time at Each Place", Preferences.Stay.allCases.map { ($0.title, $0) },
                             current: preferences.stay) { preferences.stay = $0 })
        menu.addItem(choices("On Battery", PowerState.BatteryMode.allCases.map { ($0.title, $0) },
                             current: preferences.batteryMode) { preferences.batteryMode = $0 })
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        menu.addItem(check)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// A submenu of choices, with a check on the current one.
    private func choices<Value: Equatable>(_ title: String, _ options: [(String, Value)], current: Value,
                                           choose: @escaping @MainActor (Value) -> Void) -> NSMenuItem {
        let menu = NSMenu()
        for (name, value) in options {
            let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.state = value == current ? .on : .off
            item.representedObject = Choice { choose(value) }
            menu.addItem(item)
        }
        return submenu(title, menu)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        (sender.representedObject as? Choice)?.apply()
    }

    @objc private func fly(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let place = Place.named(id) else { return }
        fly(to: place)
    }

    private func fly(to place: Place) {
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: place, from: bottom, time: world.time)
        preferences.lastPlace = place.id
        // Let the repaint finish before painting the still.
        DispatchQueue.main.asyncAfter(deadline: .now() + Journey.sweepDuration + 0.5) { [weak self] in
            self?.refreshStill(force: true)
        }
    }

    @objc private func toggleBorder() {
        preferences.paperEdge.toggle()
    }

    @objc private func checkForUpdates() {
        updates.checkNow()
    }

    @objc private func openActivation() {
        showActivation()
    }

    @objc private func togglePause() {
        displays.isPaused.toggle()
        // The gull greys out while the world is paused.
        statusItem.button?.appearsDisabled = displays.isPaused
        if displays.isPaused { refreshStill(force: true) }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, license: license)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Outbound Settings"
            window.styleMask = [.titled, .closable]
            window.showsOnlyCloseButton()
            window.opensWhereTheUserIs()
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // Once the menu it was chosen from has closed.
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.bringForward() }
    }
}

/// A menu item's choice, run when it is picked.
@MainActor
private final class Choice: NSObject {
    let apply: @MainActor () -> Void

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
    }
}

extension NSApplication {
    /// Brings Outbound's windows to the front, the way each version of macOS asks for it.
    func comeForward() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

extension NSWindow {
    /// Shows the window in front of every other app's windows. Outbound has no Dock icon, and since macOS 14
    /// the system can turn down its request to become the active app, which would leave the window behind the
    /// app in front; it comes to the front anyway, and takes the keyboard once Outbound is active.
    func bringForward() {
        NSApp.comeForward()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    /// Opens on the desktop the user is looking at, even beside a full-screen app, rather than switching back to
    /// the one it was last open on.
    func opensWhereTheUserIs() {
        collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
    }
}

private extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
