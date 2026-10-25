import AppKit
import OutboundCore

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            NSApp.terminate(nil)
            return
        }
        let gpu: GPU
        do {
            gpu = try GPU()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Outbound could not start its renderer."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let world = World(place: Place.all[0], time: CACurrentMediaTime())
        displays = DisplayManager(world: world, gpu: gpu)
        displays.start()
        installStatusItem()
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Outbound")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let world = displays.world
        let leg = world.journey.leg(at: world.camera.y)
        let here = NSMenuItem(title: leg.place.name, action: nil, keyEquivalent: "")
        here.isEnabled = false
        menu.addItem(here)
        let season = NSMenuItem(title: leg.season.line, action: nil, keyEquivalent: "")
        season.isEnabled = false
        menu.addItem(season)
        menu.addItem(.separator())

        let flyTo = NSMenuItem(title: "Fly To", action: nil, keyEquivalent: "")
        let places = NSMenu()
        for place in Place.all {
            let item = NSMenuItem(title: place.name, action: #selector(fly(_:)), keyEquivalent: "")
            item.representedObject = place.id
            item.target = self
            item.state = place.id == leg.place.id ? .on : .off
            places.addItem(item)
        }
        flyTo.submenu = places
        menu.addItem(flyTo)

        let pause = NSMenuItem(title: displays.isPaused ? "Resume" : "Pause", action: #selector(togglePause),
                               keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func fly(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let place = Place.named(id) else { return }
        let world = displays.world
        let bottom = world.camera.y + Double(world.desktop.minY) * World.metresPerPoint - 50
        world.journey.fly(to: place, from: bottom, time: world.time)
    }

    @objc private func togglePause() {
        displays.isPaused.toggle()
    }
}
