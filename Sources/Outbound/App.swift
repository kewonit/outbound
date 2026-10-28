import AppKit
import Combine
import OutboundCore
import ServiceManagement
import SwiftUI

@main
@MainActor
enum OutboundApp {
    static let delegate = AppDelegate()
    /// When Outbound began, for the log line saying how soon each display's painting was up.
    static var launched: CFTimeInterval = 0

    static func main() {
        launched = CACurrentMediaTime()
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
    private var stillsWereOn = false
    private var paintingTimer: Timer?
    /// What the painting on the desktop last showed: its place, its light, the world's moment, and when it was made.
    private var painted = (leg: -1, revision: -1, time: 0.0, at: -TimeInterval.infinity)
    /// A new painting was asked for, say for a new border or pace, but couldn't be made then.
    private var owesPainting = false
    /// The session is ending (logging out, restarting, shutting down), as the quit itself says.
    private var sessionEnding = false
    /// When the Mac last unlocked: the desktop picture shows through as the desktop fades back in, so it is left alone
    /// for a moment.
    private var unlockedAt = -TimeInterval.infinity
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
        do {
            gpu = try GPU()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Outbound could not start its renderer.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        stills = StillWriter(gpu: gpu)
        // Opened over a painting the last run left on the desktop, as at login after a restart, the view carries on from
        // the moment it shows, so the desktop picture gives way to the same view rather than another part of the place.
        let now = CACurrentMediaTime()
        let resumed = stills.momentLeft().flatMap { World(resuming: $0, at: now, light: preferences.light) }
        if resumed != nil { Log.display.info("Opening on the moment the painting on the desktop shows") }
        let world = resumed
            ?? World(place: Place.named(preferences.lastPlace) ?? .first, time: now, light: preferences.light)
        displays = DisplayManager(world: world, gpu: gpu, power: PowerMonitor(batteryMode: preferences.batteryMode))
        updates = Updates()
        updates.isQuiet = { [weak self] in self?.displays.isQuiet ?? false }
        displays.onQuiet = { [weak self] in self?.updates.installIfQuiet() }
        stillsWereOn = preferences.matchingStill
        applyPreferences()
        if !LicenseController.isGated { displays.note = String(localized: "Development build") }
        displays.running = license.unlocks
        displays.onReveal = { [weak self] in self?.refreshPainting(force: false) }
        displays.start()
        // Only Outbound's own windows need it, so it waits until the wallpapers' first frames are on their way.
        installMainMenu()
        // Launched while the Mac is locked, as an update installs, the painting on the lock screen stays as it is.
        // Otherwise the desktop picture becomes a painting as each wallpaper comes up over it, in place of any left
        // there by the last launch; with the painting off, that one goes back to the user's own picture.
        if displays.isLocked { lockChanged(true) }
        if !paintsDesktop { restorePictures() }
        displays.onLockChange = { [weak self] locked in self?.lockChanged(locked) }
        // macOS keeps a picture for each desktop, so check each one as it comes into view, once it has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A painting on its way for the desktop just left never lands, and is made again.
                if self?.stills.desktopsMoved() == true { self?.painted.leg = -1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.desktopChanged() }
            }
        }
        installStatusItem()
        observePreferences()
        paintingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPainting(force: false) }
        }

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

    /// Whether the desktop picture is a painting of the view while Outbound runs.
    private var paintsDesktop: Bool {
        preferences.matchingStill && license.unlocks
    }

    /// Keeps the painting on the desktop close to the view, so the moment it shows is never far behind: on a new place
    /// or a change of light or pace, after a Fly To or a pause, on a display or desktop showing an older one, and
    /// otherwise every five minutes while someone is watching it move. Never mid-sweep or while new light is still
    /// spreading over the ground, and only on displays in view: a full-screen app's desktop goes away with it, and a
    /// painting there would never be put back. With the painting off, puts back the user's own picture if that was
    /// asked for while the Mac was locked.
    private func refreshPainting(force: Bool) {
        guard paintsDesktop else {
            if stills.owesRestore, CACurrentMediaTime() - unlockedAt > 3 { restorePictures() }
            return
        }
        let force = force || owesPainting
        guard !displays.isQuiet else {
            owesPainting = force
            return
        }
        let shown = displays.wallpapersInView
        // Looked at every time, so the Mac locking knows which paintings are on screen.
        let showsOneMoment = stills.showsOneMoment(shown)
        guard !world.isSweeping, !shown.isEmpty, !shown.contains(where: \.isRepainting),
              CACurrentMediaTime() - unlockedAt > 3 else {
            owesPainting = force
            return
        }
        let leg = world.journey.leg(at: world.camera.y).index
        let stale = world.time != painted.time && CACurrentMediaTime() - painted.at > 300
        let renewed = force || leg != painted.leg || world.revision != painted.revision || stale
        guard renewed || !showsOneMoment else { return }
        // Only a desktop come into view, or one showing something else: it gets the painting the others show.
        if !renewed, stills.carry(shown) { return }
        painted = (leg, world.revision, world.time, CACurrentMediaTime())
        owesPainting = false
        stills.paint(shown, at: world.moment())
    }

    /// Another desktop is in view: it gets the painting the others show, unless it already shows it; with the painting
    /// turned off, one left there goes back to the user's own picture.
    private func desktopChanged() {
        if !paintsDesktop {
            restorePictures()
        } else {
            refreshPainting(force: false)
        }
    }

    /// The lock screen comes up showing the painting on the desktop before anyone is told the Mac is locking, and a
    /// change to it then shows as the lock screen settling twice. So nothing on it changes: the wallpapers go back,
    /// behind it, to the moment that painting shows, and carry on from there once the Mac unlocks, so the desktop
    /// comes back just as the lock screen left it.
    private func lockChanged(_ locked: Bool) {
        guard locked else {
            stills.unlock()
            unlockedAt = CACurrentMediaTime()
            return
        }
        // A painting dropped on its way is asked for again once the Mac unlocks.
        if stills.lock() { painted.leg = -1 }
        let wallpapers = displays.wallpapers.values
        guard paintsDesktop,
              let moment = wallpapers.compactMap({ stills.moment(givenTo: $0) }).max(by: { $0.time < $1.time })
        else { return }
        guard world.canRewind(to: moment) else {
            Log.display.info("Locked: the painting's moment is out of reach, so the view may change on unlocking")
            return
        }
        let back = world.time - moment.time
        world.rewind(to: moment)
        // Frames now ask for ground from that far back.
        gpu.paintBudget.rewind(by: back)
        wallpapers.forEach { $0.redraw() }
        Log.display.info("Locked: back \(String(format: "%.1f", back), privacy: .public) s to the painting's moment")
    }

    private func licenseChanged(_ unlocked: Bool) {
        if unlocked {
            displays.running = true
            activation?.finish()
        } else {
            // While the wallpapers still cover the desktop, so the change never shows.
            restorePictures()
            displays.running = false
            showActivation()
        }
    }

    /// Puts the user's own pictures back: on the desktops in view, leaving any painting that may still be on a desktop
    /// under a full-screen app, then on every desktop out of view where the system allows it, that one included.
    private func restorePictures() {
        stills.restore(keeping: displays.occludedDisplays)
        stills.restoreOtherDesktops()
    }

    private func showActivation() {
        if activation == nil {
            let window = ActivationWindow(license: license, world: world, gpu: gpu)
            window.onDone = { [weak self] in self?.activation = nil }
            window.paperEdge = preferences.paperEdge
            activation = window
        }
        activation?.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logging out, restarting and shutting down quit each app with an Apple event that says why. One cancelled
        // before reaching Outbound never gets here.
        sessionEnding = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard displays != nil else { return }
        preferences.lastPlace = world.journey.leg(at: world.camera.y).place.id
        // Leave the desktop as the user had it before Outbound. The painting stays while the Mac is locked or its
        // screens are asleep, as an update installs, and as the session ends when Outbound opens again at login,
        // for the login window; the next launch carries on from it.
        let opensAgain = sessionEnding && SMAppService.mainApp.status == .enabled
        if !opensAgain, !displays.isAsleep { restorePictures() }
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
        if journey.speed != preferences.pace.speed {
            journey.setSpeed(preferences.pace.speed, at: world.time)
            // A painting from before shows a moment the new pace never passed through.
            if stills != nil { refreshPainting(force: true) }
        }
        journey.staysPut = preferences.stay == .forever
        if preferences.stay != .forever { journey.legLength = Double(preferences.stay.rawValue) * 60 * preferences.pace.speed }
        displays.power.batteryMode = preferences.batteryMode
        displays.rest.after = preferences.restsWhenAway && !measuring ? 300 : nil
        displays.pausesWhenHidden = preferences.pausesWhenHidden
        let edgeChanged = displays.paperEdge != preferences.paperEdge
        displays.paperEdge = preferences.paperEdge
        activation?.paperEdge = preferences.paperEdge
        if stills != nil {
            if stillsWereOn, !preferences.matchingStill { restorePictures() }
            if edgeChanged || preferences.matchingStill != stillsWereOn { refreshPainting(force: true) }
        }
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
        guard license.unlocks else {
            let unlock = NSMenuItem(title: String(localized: "Unlock Outbound…"), action: #selector(openActivation), keyEquivalent: "")
            unlock.target = self
            menu.addItem(unlock)
            menu.addItem(feedbackItem())
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
        let hidden = NSMenuItem(title: String(localized: "Pause When Hidden"), action: #selector(togglePausesWhenHidden),
                                keyEquivalent: "")
        hidden.target = self
        hidden.state = preferences.pausesWhenHidden ? .on : .off
        menu.addItem(hidden)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let check = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        menu.addItem(check)
        menu.addItem(feedbackItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Outbound"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Just above Quit, whether or not Outbound is unlocked. It opens a web page, so in place of an ellipsis it shows
    /// an outward arrow, set as a key equivalent with no modifiers so it sits on the right with ⌘, and ⌘Q. Nobody can
    /// type it.
    private func feedbackItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Feedback"), action: #selector(openFeedback), keyEquivalent: "↗")
        item.keyEquivalentModifierMask = []
        item.target = self
        return item
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
        // Once the new place has swept in.
        DispatchQueue.main.asyncAfter(deadline: .now() + Journey.sweepDuration + 0.5) { [weak self] in
            self?.refreshPainting(force: true)
        }
    }

    @objc private func toggleBorder() {
        preferences.paperEdge.toggle()
    }

    @objc private func togglePausesWhenHidden() {
        preferences.pausesWhenHidden.toggle()
    }

    @objc private func checkForUpdates() {
        updates.checkNow()
    }

    @objc private func openActivation() {
        showActivation()
    }

    /// The feedback page in the browser, on the same site as the shop. Its address says which version of Outbound the
    /// message is about, and nothing else.
    @objc private func openFeedback() {
        let site = Store.shop.deletingLastPathComponent()
        guard var page = URLComponents(url: site.appendingPathComponent("feedback"), resolvingAgainstBaseURL: false) else { return }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            page.queryItems = [URLQueryItem(name: "app", value: version)]
        }
        if let url = page.url { NSWorkspace.shared.open(url) }
    }

    @objc private func togglePause() {
        displays.isPaused.toggle()
        // The gull greys out while the world is paused.
        statusItem.button?.appearsDisabled = displays.isPaused
        if displays.isPaused { refreshPainting(force: true) }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, license: license)
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
