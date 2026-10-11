import AppKit
import KeyboardShortcuts
import OutboundCore
import SwiftUI

@main
@MainActor
enum OutboundApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showNotification = Notification.Name("app.outbound.Outbound.show")

    private var statusItem: NSStatusItem!
    private var model: Model!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning {
            DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil,
                                                                         deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showFromOtherInstance),
                                                            name: Self.showNotification, object: nil)
        installMainMenu()
        installStatusItem()

        model = Model(store: LibraryStore(url: libraryURL))
        model.onProblem = { [weak self] in self?.present($0) }
        do {
            try model.load()
        } catch {
            failToOpenLibrary(error)
            return
        }
        panel = PanelController(model: model)
        panel.openSettings = { [weak self] in self?.openSettings() }
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            guard let self else { return }
            panel.toggle(below: statusItemFrame)
        }
        if model.library.prompts.isEmpty { panel.show(below: statusItemFrame) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show(below: statusItemFrame)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.save()
    }

    private var libraryURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OUTBOUND_LIBRARY"] { return URL(filePath: path) }
        #endif
        return LibraryStore.defaultURL
    }

    private var isAlreadyRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }

    @objc private func showFromOtherInstance() {
        panel?.show(below: statusItemFrame)
    }

    private var statusItemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "Outbound")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            panel?.toggle(below: statusItemFrame)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        panel?.hide()
        if settingsWindow == nil {
            let settings = SettingsView(libraryURL: model.libraryURL,
                                        importPrompts: { [weak self] in self?.model.importPrompts(from: $0) ?? 0 })
            let controller = NSHostingController(rootView: settings)
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = "Outbound Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func present(_ problem: Model.Problem) {
        let alert = NSAlert()
        switch problem {
        case .movedAside(let url):
            alert.messageText = "Your library couldn't be read"
            alert.informativeText = "The file was moved aside so nothing is lost, and Outbound started a new library."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .saveFailed(let error):
            alert.messageText = "Outbound couldn't save your library"
            alert.informativeText = "\(error.localizedDescription) Your changes are still here and will be saved with the next edit."
            NSApp.activate()
            alert.runModal()
        }
    }

    private func failToOpenLibrary(_ error: Error) {
        let alert = NSAlert()
        if case LibraryError.newerVersion = error {
            alert.messageText = "Your library is from a newer version of Outbound"
            alert.informativeText = "Update Outbound to open it. The file has not been changed."
        } else {
            alert.messageText = "Outbound couldn't open your library"
            alert.informativeText = error.localizedDescription
        }
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Accessory apps still need menus for standard shortcuts to work in their windows.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Outbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
