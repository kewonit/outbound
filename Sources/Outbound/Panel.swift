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
    let model: Model
    var openSettings: () -> Void = {}
    private let panel: Panel
    private var lastHidden = Date.distantPast

    init(model: Model) {
        self.model = model
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.maxHeight),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        model.onLeaveEditor = { [weak panel] in panel?.undoManager?.removeAllActions() }

        // Frosted like a popover. Liquid Glass would add a bright rim around the edge.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 18)
        let content = NSHostingView(rootView: PanelView(model: model, actions: actions))
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background
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
        fitToContent()
    }

    var isVisible: Bool { panel.isVisible }

    /// A stretchable rounded rectangle, so the blur keeps its corners at any panel height.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private var actions: PanelActions {
        PanelActions(use: { [weak self] prompt, paste in self?.use(prompt, paste: paste) })
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

    // MARK: Size

    /// Tall enough for what is showing and no taller, like Spotlight.
    private var fittingHeight: CGFloat {
        let items = CGFloat(model.library.categories.count + 2)
        let rail = Metrics.railInset * 2 + items * Metrics.railItem + (items - 1) * Metrics.railGap
        let content: CGFloat
        switch model.mode {
        case .browse:
            let rows = CGFloat(max(model.results.count, 1))
            content = Metrics.header + Metrics.line + Metrics.listInset * 2 + rows * Metrics.row + (rows - 1) * Metrics.rowGap
        case .category:
            content = CategoryEditor.height
        case .prompt(let id):
            content = Metrics.header + Metrics.line + editorHeight(for: model.library.prompt(id)?.body ?? "")
        }
        return min(max(content, rail), Metrics.maxHeight)
    }

    /// The body grows with its text, starting at a few lines, so short prompts stay compact.
    private func editorHeight(for text: String) -> CGFloat {
        // Long prompts always fill the panel, so skip measuring them on every keystroke.
        guard text.utf16.count < 1500 else { return Metrics.maxHeight }
        let font = BodyEditor.font
        let width = Metrics.width - Metrics.railWidth - Metrics.line - BodyEditor.inset.width * 2 - 10
        let text = text.isEmpty ? " " : text
        let measured = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: font]).height
        let line = font.ascender - font.descender + font.leading
        return max(ceil(measured + line) + BodyEditor.inset.height * 2, 150)
    }

    /// Follows the content as it changes, keeping the top edge in place under the menu bar.
    private func fitToContent() {
        withObservationTracking {
            _ = fittingHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resize()
                self?.fitToContent()
            }
        }
    }

    private func resize() {
        guard panel.isVisible, let screen = panel.screen else { return }
        var frame = panel.frame
        let height = min(fittingHeight, screen.visibleFrame.height - 16)
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Centered under the menu bar icon, or at the top right of the screen with the pointer
    /// when the icon is hidden or on another display.
    private func frame(below anchor: NSRect?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        let visible = screen.visibleFrame
        let anchor = anchor.flatMap { screen.frame.contains(NSPoint(x: $0.midX, y: $0.midY)) ? $0 : nil }
        let size = CGSize(width: min(Metrics.width, visible.width - 16),
                          height: min(fittingHeight, visible.height - 16))
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
        hide()
        if paste { Paster.paste(prompt.body) } else { Paster.copy(prompt.body) }
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
        if handleTextCommand(key, flags: flags) { return true }
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
        let inField = (panel.firstResponder as? NSTextView)?.isFieldEditor == true
        let next = [KeyCode.returnKey, KeyCode.enter, KeyCode.tab].contains(event.keyCode)
        if event.keyCode == KeyCode.escape {
            model.back()
        } else if inField, next, case .prompt = model.mode {
            model.focus(.body)
        } else if inField, next {
            model.back()
        } else {
            return false
        }
        return true
    }

    /// Text editing shortcuts, sent straight to the focused text so they work
    /// even though the panel never activates the app.
    private func handleTextCommand(_ key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard panel.firstResponder is NSTextView else { return false }
        let action: Selector? = switch (flags, key) {
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "z") where model.mode != .browse: Selector(("undo:"))
        case ([.command, .shift], "z") where model.mode != .browse: Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: panel)
    }
}

struct PanelActions {
    var use: (Prompt, _ paste: Bool) -> Void
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
