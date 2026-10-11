import AppKit
import SwiftUI
import OutboundCore

struct PromptEditor: View {
    @Bindable var model: Model
    let id: UUID
    var focus: FocusState<Model.Field?>.Binding

    var body: some View {
        let prompt = model.library.prompt(id) ?? Prompt(id: id)
        let fallbackTitle = Prompt(body: prompt.body).displayTitle
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: model.back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("Back")
                TextField(fallbackTitle.isEmpty ? "Title" : fallbackTitle,
                          text: Binding(get: { prompt.title }, set: { model.setTitle($0, of: id) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused(focus, equals: .title)
                categoryMenu(prompt)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider()
            BodyEditor(text: Binding(get: { prompt.body }, set: { model.setBody($0, of: id) }),
                       focusCount: model.focusRequest.field == .body ? model.focusRequest.count : nil)
        }
    }
}

extension PromptEditor {
    private func categoryMenu(_ prompt: Prompt) -> some View {
        Menu {
            Picker("Category", selection: Binding(get: { prompt.categoryID },
                                                  set: { model.setCategory($0, of: id) })) {
                Text("None").tag(UUID?.none)
                ForEach(model.library.categories) { category in
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Group {
                if let category = model.library.category(prompt.categoryID) {
                    CategoryIcon(category: category)
                } else {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("Category")
    }
}

/// A plain text view that leaves prompts exactly as typed: no smart quotes, dashes or corrections.
struct BodyEditor: NSViewRepresentable {
    @Binding var text: String
    let focusCount: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = BodyTextView(usingTextLayoutManager: true)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? BodyTextView else { return }
        if textView.string != text, !textView.hasMarkedText() { textView.string = text }
        if let focusCount, focusCount != context.coordinator.focusCount {
            context.coordinator.focusCount = focusCount
            textView.focus()
        }
    }

    /// Takes focus as soon as it is in a window, since SwiftUI adds it before that.
    final class BodyTextView: NSTextView {
        private var wantsFocus = false

        func focus() {
            wantsFocus = true
            focusIfPossible()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfPossible()
        }

        private func focusIfPossible() {
            guard wantsFocus, let window else { return }
            wantsFocus = false
            DispatchQueue.main.async { window.makeFirstResponder(self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BodyEditor
        var focusCount: Int?

        init(_ parent: BodyEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
