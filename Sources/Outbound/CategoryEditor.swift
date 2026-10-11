import SwiftUI
import OutboundCore

struct CategoryEditor: View {
    static let symbols = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "sparkles", "lightbulb.fill",
        "bookmark.fill", "tag.fill", "flag.fill", "briefcase.fill", "folder.fill", "doc.text.fill", "pencil",
        "paintbrush.fill", "hammer.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "envelope.fill", "bubble.left.fill", "person.fill", "globe", "magnifyingglass", "book.fill",
        "graduationcap.fill", "chart.bar.fill", "camera.fill", "music.note", "house.fill", "cart.fill"
    ]

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
            .frame(height: 52)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 6) {
                    ForEach(CategoryColor.allCases, id: \.self) { color in
                        choice(selected: category.color == color, name: color.rawValue.capitalized) {
                            model.updateCategory(id) { $0.color = color }
                        } label: {
                            Circle().fill(color.color).frame(width: 16, height: 16)
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
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
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func choice<Label: View>(selected: Bool, name: String, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 32)
                .background(Circle().fill(.primary.opacity(selected ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
