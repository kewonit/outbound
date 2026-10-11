import SwiftUI
import OutboundCore

struct CategoryEditor: View {
    /// Icons that fit a prompt library. Outline glyphs, like a Mac sidebar.
    static let symbols = [
        "star", "text.alignleft", "pencil", "envelope", "bubble.left.and.bubble.right", "quote.bubble", "translate",
        "chevron.left.forwardslash.chevron.right", "terminal", "ladybug", "doc.text", "checklist", "list.bullet",
        "magnifyingglass", "book", "graduationcap", "lightbulb", "sparkles", "brain.head.profile", "chart.bar",
        "tablecells", "paintbrush", "photo", "megaphone", "briefcase", "person", "calendar", "scroll", "hammer",
        "gearshape", "bookmark"
    ]

    static let columns = 8
    static let cell: CGFloat = 32
    static let gap: CGFloat = 6
    static let inset: CGFloat = 16

    /// Header, colors, then the icon grid, with nothing to spare.
    static var height: CGFloat {
        let rows = CGFloat((symbols.count + 1 + columns - 1) / columns)
        return Metrics.header + Metrics.line + inset * 2 + cell + 20 + rows * cell + (rows - 1) * gap
    }

    @Bindable var model: Model
    let id: UUID
    var focus: FocusState<Model.Field?>.Binding

    var body: some View {
        let category = model.library.category(id) ?? PromptCategory(id: id, name: "")
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
                TextField("Name", text: Binding(get: { category.name },
                                                set: { name in model.updateCategory(id) { $0.name = name } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused(focus, equals: .categoryName)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.header)
            Hairline()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: Self.gap) {
                    ForEach(CategoryColor.allCases, id: \.self) { color in
                        choice(selected: category.color == color, name: color.rawValue.capitalized) {
                            model.updateCategory(id) { $0.color = color }
                        } label: {
                            Circle().fill(color.color).frame(width: 16, height: 16)
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.gap), count: Self.columns),
                          spacing: Self.gap) {
                    choice(selected: category.symbol == nil, name: "Dot") {
                        model.updateCategory(id) { $0.symbol = nil }
                    } label: {
                        Circle().fill(category.color.color).frame(width: 10, height: 10)
                    }
                    ForEach(Self.symbols, id: \.self) { symbol in
                        choice(selected: category.symbol == symbol, name: symbol) {
                            model.updateCategory(id) { $0.symbol = symbol }
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(category.color.color)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(Self.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func choice<Label: View>(selected: Bool, name: String, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: Self.cell, height: Self.cell)
                .background(Circle().fill(.primary.opacity(selected ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
