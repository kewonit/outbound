import AppKit
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
    private var licenseTimer: Timer?
    private var settingsWindow: NSWindow?
    private var stillTimer: Timer?
    private var stillLeg = -1
    private var stillTaken = Date.distantPast
    private var stillsWereOn = false
    private var signals: [DispatchSourceSignal] = []
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
            alert.messageText = "Outbound could not start its renderer."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let place = Place.named(preferences.lastPlace) ?? Place.all[0]
        let world = World(place: place, time: CACurrentMediaTime(), light: preferences.light)
        displays = DisplayManager(world: world, gpu: gpu, power: PowerMonitor(batteryMode: preferences.batteryMode))
        stills = StillWriter(gpu: gpu)
        stillsWereOn = preferences.matchingStill
        applyPreferences()
        if !LicenseController.isGated { displays.note = "Development build" }
        displays.running = license.unlocks
        displays.start()
        // A painting left behind by a crash, or by a license that has since lapsed, goes back to the user's own.
        if !(preferences.matchingStill && license.unlocks) { stills.restore() }
        installStatusItem()
        observePreferences()

        // Keep the real desktop picture close to what is on screen, checking twice a minute for a new place.
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
    }

    private func licenseChanged(_ unlocked: Bool) {
        displays.running = unlocked
        if unlocked {
            activation?.finish()
            activation = nil
            refreshStill(force: true)
        } else {
            stills.restore()
            showActivation()
        }
    }

    private func showActivation() {
        if activation == nil { activation = ActivationWindow(license: license, world: world, gpu: gpu) }
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
        withObservationTracking {
            _ = (preferences.light, preferences.followsCalendar, preferences.pace, preferences.stay,
                 preferences.batteryMode, preferences.matchingStill, preferences.restsWhenAway)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyPreferences()
                self?.observePreferences()
            }
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
        journey.legLength = Double(preferences.stay.rawValue) * 60 * preferences.pace.speed
        displays.power.batteryMode = preferences.batteryMode
        displays.rest.after = preferences.restsWhenAway ? 300 : nil
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
        stills.capture(world: world)
    }

    // MARK: - Menu

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Outbound")
        let menu = NSMenu()
        menu.delegate = self
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
        for place in Place.all {
            let item = NSMenuItem(title: place.name, action: #selector(fly(_:)), keyEquivalent: "")
            item.representedObject = place.id
            item.target = self
            item.state = place.id == leg.place.id ? .on : .off
            places.addItem(item)
        }
        menu.addItem(submenu("Fly To", places))

        let lights = NSMenu()
        for light in World.Light.allCases {
            let item = NSMenuItem(title: light.title, action: #selector(setLight(_:)), keyEquivalent: "")
            item.representedObject = light.rawValue
            item.target = self
            item.state = light == preferences.light ? .on : .off
            lights.addItem(item)
        }
        menu.addItem(submenu("Light", lights))

        let pause = NSMenuItem(title: displays.isPaused ? "Resume" : "Pause", action: #selector(togglePause),
                               keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func fly(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let place = Place.named(id) else { return }
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: place, from: bottom, time: world.time)
        preferences.lastPlace = place.id
        // Let the repaint finish before painting the still.
        DispatchQueue.main.asyncAfter(deadline: .now() + Journey.sweepDuration + 0.5) { [weak self] in
            self?.refreshStill(force: true)
        }
    }

    @objc private func setLight(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let light = World.Light(rawValue: raw) else { return }
        preferences.light = light
    }

    @objc private func openActivation() {
        showActivation()
    }

    @objc private func togglePause() {
        displays.isPaused.toggle()
        if displays.isPaused { refreshStill(force: true) }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, license: license)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Outbound Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
