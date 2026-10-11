import AppKit
import SwiftUI
import OutboundCore

struct Rail: View {
    @Bindable var model: Model

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                RailButton(name: "All Prompts", selected: model.scope == nil) {
                    model.scope = nil
                } icon: {
                    Image(systemName: "tray.full")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.library.categories) { category in
                    RailButton(name: category.name, selected: model.scope == category.id) {
                        model.scope = category.id
                    } icon: {
                        CategoryIcon(category: category)
                    }
                }
            }
            .padding(.vertical, 11)
        }
        .scrollIndicators(.never)
        .frame(width: 50)
    }
}

struct RailButton<Icon: View>: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 30, height: 30)
                .background(Circle().fill(.primary.opacity(selected ? 0.12 : hovering ? 0.06 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
