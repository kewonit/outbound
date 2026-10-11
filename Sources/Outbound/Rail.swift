import AppKit
import SwiftUI
import OutboundCore

struct Rail: View {
    @Bindable var model: Model

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: Metrics.railGap) {
                RailButton(name: "All Prompts", selected: model.scope == nil) {
                    model.scope = nil
                } icon: {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } drop: { items in
                    model.move(items.ids(.prompt), to: nil)
                }
                ForEach(model.library.categories) { category in
                    RailButton(name: category.name, selected: model.scope == category.id) {
                        model.scope = category.id
                    } icon: {
                        CategoryIcon(category: category)
                    } drop: { items in
                        model.move(items.ids(.prompt), to: category.id)
                        model.reorderCategories(items.ids(.category), before: category.id)
                    }
                    .draggable(DragItem(kind: .category, id: category.id, text: category.name)) {
                        CategoryIcon(category: category).padding(8)
                    }
                    .contextMenu {
                        Button("Edit") { model.editCategory(category.id) }
                        Divider()
                        Button("Delete") { model.deleteCategory(category.id) }
                    }
                }
                RailButton(name: "New Category", selected: false, action: model.newCategory) {
                    Image(systemName: "plus.circle.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } drop: { items in
                    model.reorderCategories(items.ids(.category), before: nil)
                }
            }
            .padding(.vertical, Metrics.railInset)
        }
        .scrollIndicators(.never)
        .frame(width: Metrics.railWidth)
    }
}

struct RailButton<Icon: View>: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    let drop: ([DragItem]) -> Void
    @State private var hovering = false
    @State private var targeted = false

    // Not a Button, so categories can be dragged.
    var body: some View {
        icon
            .frame(width: Metrics.railItem, height: Metrics.railItem)
            .background(Circle().fill(.primary.opacity(selected || targeted ? 0.12 : hovering ? 0.06 : 0)))
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .dropDestination(for: DragItem.self) { items, _ in
                drop(items)
                return true
            } isTargeted: { targeted = $0 }
            .help(name)
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

struct CategoryIcon: View {
    let category: PromptCategory
    var size: CGFloat = 13

    var body: some View {
        if let symbol = category.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(category.color.color)
        } else {
            Circle()
                .fill(category.color.color)
                .frame(width: size * 0.75, height: size * 0.75)
        }
    }
}

extension CategoryColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}
