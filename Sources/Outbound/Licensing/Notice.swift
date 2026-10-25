import AppKit
import SwiftUI

/// A small window with a message and a button or two, for things worth saying when a link from the browser
/// arrives. Unlike a modal alert it never holds up the app, and it waits for an answer however long it takes.
@MainActor
enum Notice {
    /// Shows the notice and returns the index of the button clicked, or nil if it was closed.
    @discardableResult
    static func show(_ title: String, detail: String, buttons: [String] = ["OK"]) async -> Int? {
        await withCheckedContinuation { continuation in
            NoticePanel(title: title, detail: detail, buttons: buttons, answer: continuation).present()
        }
    }
}

/// One notice on screen. It keeps itself alive through its window until it has an answer.
@MainActor
private final class NoticePanel {
    private let panel: NSPanel
    private var answer: CheckedContinuation<Int?, Never>?
    private var observer: NSObjectProtocol?

    init(title: String, detail: String, buttons: [String], answer: CheckedContinuation<Int?, Never>) {
        self.answer = answer
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 140),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let view = NoticeView(title: title, detail: detail, buttons: buttons) { [self] index in finish(index) }
        panel.contentViewController = NSHostingController(rootView: view)
    }

    func present() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                          queue: .main) { [self] _ in
            MainActor.assumeIsolated { finish(nil) }
        }
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ index: Int?) {
        guard let answer else { return }
        self.answer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel.close()
        // The window held this notice through its buttons; let go so both can be freed.
        panel.contentViewController = nil
        answer.resume(returning: index)
    }
}

private struct NoticeView: View {
    let title: String
    let detail: String
    let buttons: [String]
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                ForEach(Array(buttons.enumerated().reversed()), id: \.offset) { index, title in
                    if index == 0 {
                        Button(title) { choose(index) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(title) { choose(index) }
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
