import AppKit
import Combine
import OutboundCore
import SwiftUI

@main
@MainActor
enum OutboundApp {
    static let delegate = AppDelegate()
    /// When Outbound began, for the log line saying how soon each display's painting was up.
    static var launched: CFTimeInterval = 0

    static func main() {
        launched = CACurrentMediaTime()
        #if !APPSTORE
        // The renderer behind the site's pictures; the App Store copy is only the wallpaper.
        let arguments = CommandLine.arguments
        if Exporter.handles(arguments) { exit(Exporter.run(arguments)) }
        #endif
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
    #if !APPSTORE
    private let license = LicenseController()
    private var updates: Updates!
    private var licenseTimer: Timer?
    /// Links from the thank-you page that arrived before launch finished.
    private var earlyLinks: [ActivationLink] = []
    #endif
    private var activation: ActivationWindow?
    private var gpu: GPU!
    private var settingsWindow: NSWindow?
    private var stillsWereOn = false
    private var signals: [DispatchSourceSignal] = []
    private var preferencesChanged: AnyCancellable?

    private var world: World { displays.world }

    /// Whether this copy may fly. One from the App Store always may: the store sold it.
    private var unlocked: Bool {
        #if APPSTORE
        true
        #else
        license.unlocks
        #endif
    }

    #if APPSTORE
    private static let welcomedKey = "welcomed"
    #endif

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
        do {
            gpu = try GPU()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Outbound could not start its renderer.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let place = Place.named(preferences.lastPlace) ?? .first
        let world = World(place: place, time: CACurrentMediaTime(), light: preferences.light)
        displays = DisplayManager(world: world, gpu: gpu, power: PowerMonitor(batteryMode: preferences.batteryMode))
        stills = StillWriter(gpu: gpu)
        #if !APPSTORE
        updates = Updates()
        updates.isQuiet = { [weak self] in self?.displays.isQuiet ?? false }
        displays.onQuiet = { [weak self] in self?.updates.installIfQuiet() }
        #endif
        stillsWereOn = preferences.matchingStill
        applyPreferences()
        #if !APPSTORE
        if !LicenseController.isGated { displays.note = String(localized: "Development build") }
        #endif
        displays.running = unlocked
        displays.start()
        // Only Outbound's own windows need it, so it waits until the wallpapers' first frames are on their way.
        installMainMenu()
        // Launched while the Mac is locked, as an update installs, the lock screen gets this launch's own painting.
        // Otherwise a painting left as the desktop picture, by a crash, an update or an older version, goes back to
        // the user's own picture once the wallpapers are up over it.
        if displays.isLocked { lockChanged(true) } else { stills.restoreOnceSettled() }
        displays.onLockChange = { [weak self] locked in self?.lockChanged(locked) }
        // macOS keeps a picture for each desktop, so check each one as it comes into view, once it has settled.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stills.restoreOnceSettled() }
        }
        installStatusItem()
        observePreferences()

        #if APPSTORE
        // Says where Outbound lives, once: it has no Dock icon, only the gull in the menu bar.
        if !UserDefaults.standard.bool(forKey: Self.welcomedKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomedKey)
            showActivation()
        }
        #else
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
        #endif
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
    /// wave) and a Fly To, forty seconds apart after twenty-five seconds of plain flying, then the bird chasing a
    /// pretend cursor for fifteen seconds and gliding off again.
    private func exercise() {
        let moments: [(TimeInterval, String, () -> Void)] = [
            (25, "repaint wave", { [weak self] in self?.world.repaint() }),
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
        if locked, preferences.matchingStill, unlocked {
            stills.lock(showing: displays.wallpapers.values)
        } else if !locked {
            stills.unlock()
        }
    }

    #if !APPSTORE
    private func licenseChanged(_ unlocked: Bool) {
        displays.running = unlocked
        if unlocked {
            activation?.finish()
        } else {
            stills.restore()
            showActivation()
        }
    }
    #endif

    private func showActivation() {
        if activation == nil {
            #if APPSTORE
            let window = ActivationWindow(world: world, gpu: gpu)
            #else
            let window = ActivationWindow(license: license, world: world, gpu: gpu)
            #endif
            window.onDone = { [weak self] in self?.activation = nil }
            activation = window
        }
        activation?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard displays != nil else { return }
        preferences.lastPlace = world.journey.leg(at: world.camera.y).place.id
        // Leave the desktop as the user had it before Outbound, unless the Mac is locked (see `StillWriter.restore`).
        stills.restore()
    }

    // MARK: - Links from the thank-you page

    #if !APPSTORE
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
                let detail = email.map {
                    String(localized: "Outbound is already unlocked here with another key. The new one was bought with \($0).")
                } ?? String(localized: "Outbound is already unlocked here with another key.")
                return await Notice.show(String(localized: "Use your new key?"), detail: detail,
                                         buttons: [String(localized: "Use New Key"), String(localized: "Keep Current")]) == 0
            }
            Log.license.info("Activation link: \(String(describing: result), privacy: .public)")
            guard wasUnlocked || result == .alreadyActive else { return }
            switch result {
            case .alreadyActive: await Notice.show(String(localized: "Outbound is already unlocked."), detail: "")
            case .activated: await Notice.show(String(localized: "Outbound now uses your new key."), detail: "")
            case .failed: await Notice.show(String(localized: "That purchase didn't unlock Outbound."), detail: license.message ?? "")
            case .waiting:
                await Notice.show(String(localized: "Still processing your purchase."), detail: String(localized: "Try again in a minute."))
            case .declined: break
            }
        }
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard displays != nil else { return false }
        if unlocked { openSettings() } else { showActivation() }
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
        displays.paperEdge = preferences.paperEdge
        if stills != nil, stillsWereOn, !preferences.matchingStill { stills.restore() }
        stillsWereOn = preferences.matchingStill
    }

    // MARK: - Menu

    /// Outbound shows no menu bar, but its windows still need the usual shortcuts, and they come from the main
    /// menu: without an Edit menu, Command-V does nothing in the key field.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "Quit Outbound"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        guard unlocked else {
            let unlock = NSMenuItem(title: String(localized: "Unlock Outbound…"), action: #selector(openActivation), keyEquivalent: "")
            unlock.target = self
            menu.addItem(unlock)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: String(localized: "Quit Outbound"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
            let heading = NSMenuItem(title: String(localized: "Extended Places"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            places.addItem(heading)
            Place.extended.forEach { places.addItem(destination($0)) }
        }
        menu.addItem(submenu(String(localized: "Fly To"), places))
        let pause = NSMenuItem(title: displays.isPaused ? String(localized: "Resume") : String(localized: "Pause"), action: #selector(togglePause),
                               keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())

        // How the painting looks.
        let preferences = preferences
        menu.addItem(choices(String(localized: "Light"), World.Light.allCases.map { ($0.title, $0) }, current: preferences.light) {
            preferences.light = $0
        })
        menu.addItem(choices(String(localized: "Seasons"), [(String(localized: "What is growing there today"), true),
                                                        (String(localized: "Each place at its best"), false)],
                             current: preferences.followsCalendar) { preferences.followsCalendar = $0 })
        let border = NSMenuItem(title: String(localized: "Painted Border"), action: #selector(toggleBorder), keyEquivalent: "")
        border.target = self
        border.state = preferences.paperEdge ? .on : .off
        menu.addItem(border)
        menu.addItem(.separator())

        // How it flies.
        menu.addItem(choices(String(localized: "Pace"), Preferences.Pace.allCases.map { ($0.title, $0) }, current: preferences.pace) {
            preferences.pace = $0
        })
        menu.addItem(choices(String(localized: "Time at Each Place"), Preferences.Stay.allCases.map { ($0.title, $0) },
                             current: preferences.stay) { preferences.stay = $0 })
        menu.addItem(choices(String(localized: "On Battery"), PowerState.BatteryMode.allCases.map { ($0.title, $0) },
                             current: preferences.batteryMode) { preferences.batteryMode = $0 })
        menu.addItem(.separator())

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        #if !APPSTORE
        let check = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        menu.addItem(check)
        #endif
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Outbound"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
    }

    @objc private func toggleBorder() {
        preferences.paperEdge.toggle()
    }

    #if !APPSTORE
    @objc private func checkForUpdates() {
        updates.checkNow()
    }
    #endif

    @objc private func openActivation() {
        showActivation()
    }

    @objc private func togglePause() {
        displays.isPaused.toggle()
        // The gull greys out while the world is paused.
        statusItem.button?.appearsDisabled = displays.isPaused
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            #if APPSTORE
            let view = SettingsView(preferences: preferences)
            #else
            let view = SettingsView(preferences: preferences, license: license)
            #endif
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Outbound Settings")
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
