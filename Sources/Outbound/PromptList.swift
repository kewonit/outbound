import AppKit
import SwiftUI
import OutboundCore

struct PromptList: View {
    @Bindable var model: Model
    let actions: PanelActions
    @State private var dropTarget: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Metrics.rowGap) {
                    if model.results.isEmpty { newPromptRow }
                    ForEach(model.results) { prompt in
                        row(prompt)
                    }
                }
                .padding(Metrics.listInset)
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
            .frame(height: Metrics.row)
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
            .frame(height: Metrics.row)
            .background {
                if selected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) }
            }
            .overlay(alignment: .top) {
                if dropTarget == prompt.id {
                    Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -2)
                }
            }
            .contentShape(Rectangle())
            .id(prompt.id)
            .draggable(DragItem(kind: .prompt, id: prompt.id, text: prompt.body)) {
                Text(title.isEmpty ? "Untitled" : title).padding(Metrics.listInset)
            }
            .dropDestination(for: DragItem.self) { items, _ in
                model.reorder(items.ids(.prompt), before: prompt.id)
                return true
            } isTargeted: { targeted in
                if targeted, model.query.isEmpty { dropTarget = prompt.id }
                else if dropTarget == prompt.id { dropTarget = nil }
            }
            .onTapGesture {
                model.selection = prompt.id
                model.focus(.search)
                if NSApp.currentEvent?.clickCount == 2 { actions.use(prompt, true) }
            }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { actions.use(prompt, true) }
            .contextMenu {
                Button("Paste") { actions.use(prompt, true) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Copy") { actions.use(prompt, false) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Edit") { model.edit(prompt.id) }
                    .keyboardShortcut("e", modifiers: .command)
                if !model.library.categories.isEmpty {
                    Menu("Move To") {
                        Button("None") { model.move([prompt.id], to: nil) }
                            .disabled(prompt.categoryID == nil)
                        ForEach(model.library.categories) { category in
                            Button(category.name) { model.move([prompt.id], to: category.id) }
                                .disabled(prompt.categoryID == category.id)
                        }
                    }
                }
                Divider()
                Button("Delete") { model.delete(prompt.id) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
    }
}
