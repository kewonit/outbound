import AppKit
import SwiftUI
import OutboundCore

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the drop down panel: where it appears, when it hides, and its keyboard.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 600, height: 420)

    let model: Model
    var openSettings: () -> Void = {}
    private let panel: Panel
    private var lastHidden = Date.distantPast

    init(model: Model) {
        self.model = model
        panel = Panel(contentRect: NSRect(origin: .zero, size: Self.size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        model.onLeaveEditor = { [weak panel] in panel?.undoManager?.removeAllActions() }

        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.contentView = NSHostingView(rootView: PanelView(model: model, actions: actions))
        panel.contentView = glass
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    private var actions: PanelActions {
        PanelActions(use: { [weak self] prompt, paste in self?.use(prompt, paste: paste) },
                     openSettings: { [weak self] in self?.openSettings() })
    }

    /// Toggles from the menu bar. A click that just closed the panel by taking focus away does not reopen it.
    func toggle(below anchor: NSRect?) {
        if panel.isVisible {
            hide()
        } else if Date.now.timeIntervalSince(lastHidden) > 0.25 {
            show(below: anchor)
        }
    }

    func show(below anchor: NSRect?) {
        try? model.reloadIfChangedElsewhere()
        model.prepareToShow()
        panel.setFrame(frame(below: anchor), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        guard panel.isVisible else { return }
        lastHidden = .now
        panel.orderOut(nil)
        model.save()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// Centered under the menu bar icon, or at the top right of the screen with the pointer
    /// when the icon is hidden or on another display.
    private func frame(below anchor: NSRect?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        let visible = screen.visibleFrame
        let anchor = anchor.flatMap { screen.frame.contains(NSPoint(x: $0.midX, y: $0.midY)) ? $0 : nil }
        let size = CGSize(width: min(Self.size.width, visible.width - 16),
                          height: min(Self.size.height, visible.height - 16))
        let x = anchor.map { $0.midX - size.width / 2 } ?? visible.maxX - size.width
        return NSRect(x: min(max(x, visible.minX + 8), visible.maxX - size.width - 8),
                      y: visible.maxY - size.height - 6,
                      width: size.width, height: size.height)
    }

    private func use(_ prompt: Prompt, paste: Bool) {
        guard !prompt.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.edit(prompt.id)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt.body, forType: .string)
        hide()
    }

    // MARK: Keyboard

    /// Returns true when the key was handled here.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel, panel.isKeyWindow else { return false }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "w" { hide(); return true }
        if flags == .command, key == "," { openSettings(); return true }
        if model.mode != .browse { return handleEditorKey(event, flags: flags) }

        switch (flags, event.keyCode) {
        case ([], KeyCode.escape):
            if model.query.isEmpty { hide() } else { model.query = "" }
        case ([], KeyCode.down):
            model.moveSelection(1)
        case ([], KeyCode.up):
            model.moveSelection(-1)
        case (.control, _) where key == "n":
            model.moveSelection(1)
        case (.control, _) where key == "p":
            model.moveSelection(-1)
        case (.command, KeyCode.down):
            model.selectEdge(last: true)
        case (.command, KeyCode.up):
            model.selectEdge(last: false)
        case ([], KeyCode.returnKey), ([], KeyCode.enter):
            guard !event.isARepeat else { break }
            if let prompt = model.selectedPrompt {
                use(prompt, paste: true)
            } else if model.results.isEmpty {
                model.newPrompt()
            }
        case (.command, KeyCode.returnKey), (.command, KeyCode.enter):
            if !event.isARepeat, let prompt = model.selectedPrompt { use(prompt, paste: false) }
        case (.command, _) where key == "n":
            model.newPrompt()
        case (.command, _) where key == "e":
            if let id = model.selection { model.edit(id) }
        case (.command, KeyCode.delete):
            if let id = model.selection { model.delete(id) }
        case (.command, _) where key == "z":
            model.undo()
        case ([.command, .shift], _) where key == "z":
            model.redo()
        case (.command, _) where key.count == 1 && key.first!.isWholeNumber:
            model.selectScope(number: key.first!.wholeNumberValue!)
        default:
            return false
        }
        return true
    }

    private func handleEditorKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.isEmpty else { return false }
        let inTitle = (panel.firstResponder as? NSTextView)?.isFieldEditor == true
        if event.keyCode == KeyCode.escape {
            model.back()
        } else if inTitle, [KeyCode.returnKey, KeyCode.enter, KeyCode.tab].contains(event.keyCode) {
            model.focus(.body)
        } else {
            return false
        }
        return true
    }
}

struct PanelActions {
    var use: (Prompt, _ paste: Bool) -> Void
    var openSettings: () -> Void
}

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let enter: UInt16 = 76
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}
