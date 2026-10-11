import SwiftUI
import OutboundCore

/// Shared sizes, so the panel can fit its height to what it shows.
enum Metrics {
    static let width: CGFloat = 400
    static let maxHeight: CGFloat = 420
    static let header: CGFloat = 52
    static let line: CGFloat = 1
    static let row: CGFloat = 30
    static let rowGap: CGFloat = 2
    static let listInset: CGFloat = 6
    static let railWidth: CGFloat = 50
    static let railItem: CGFloat = 30
    static let railGap: CGFloat = 6
    static let railInset: CGFloat = 11
}

/// A separator that stays clearly visible on the frosted background.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.18))
            .frame(width: vertical ? Metrics.line : nil, height: vertical ? nil : Metrics.line)
    }
}

struct PanelView: View {
    @Bindable var model: Model
    let actions: PanelActions
    @FocusState private var focus: Model.Field?

    var body: some View {
        HStack(spacing: 0) {
            Rail(model: model)
            Hairline(vertical: true)
            Group {
                switch model.mode {
                case .browse:
                    browser
                case .prompt(let id):
                    PromptEditor(model: model, id: id, focus: $focus)
                        .id(id)
                case .category(let id):
                    CategoryEditor(model: model, id: id, focus: $focus)
                        .id(id)
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
            .frame(height: Metrics.header)
            Hairline()
            PromptList(model: model, actions: actions)
        }
    }
}
