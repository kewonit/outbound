import SwiftUI
import OutboundCore

struct PanelView: View {
    @Bindable var model: Model
    let actions: PanelActions
    @FocusState private var focus: Model.Field?

    var body: some View {
        HStack(spacing: 0) {
            Rail(model: model)
            Group {
                switch model.mode {
                case .browse:
                    browser
                case .prompt(let id):
                    PromptEditor(model: model, id: id, focus: $focus)
                        .id(id)
                case .category:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.focusRequest) { _, request in
            // The body is an AppKit text view that focuses itself.
            if request.field != .body { Task { focus = request.field } }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focus, equals: .search)
                Button(action: model.newPrompt) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("New Prompt")
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider()
            PromptList(model: model, actions: actions)
        }
    }
}
