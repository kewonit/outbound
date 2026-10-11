import AppKit
import SwiftUI
import OutboundCore

struct PromptList: View {
    @Bindable var model: Model
    let actions: PanelActions

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.results.isEmpty { newPromptRow }
                    ForEach(model.results) { prompt in
                        row(prompt)
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    /// The only thing shown when nothing matches, so Return always does something useful.
    private var newPromptRow: some View {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Label(query.isEmpty ? "New Prompt" : "New Prompt “\(query)”", systemImage: "plus")
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
            .contentShape(Rectangle())
            .onTapGesture(perform: model.newPrompt)
    }

    private func row(_ prompt: Prompt) -> some View {
        let selected = prompt.id == model.selection
        let title = prompt.displayTitle
        return Text(title.isEmpty ? "Untitled" : title)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if selected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) }
            }
            .contentShape(Rectangle())
            .id(prompt.id)
            .onTapGesture {
                model.selection = prompt.id
                if NSApp.currentEvent?.clickCount == 2 { actions.use(prompt, true) }
            }
            .contextMenu {
                Button("Paste") { actions.use(prompt, true) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Copy") { actions.use(prompt, false) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Edit") { model.edit(prompt.id) }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Delete") { model.delete(prompt.id) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
    }
}
