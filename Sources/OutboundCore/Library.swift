import Foundation

public struct Prompt: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var categoryID: UUID?
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), title: String = "", body: String = "", categoryID: UUID? = nil,
                created: Date = .now, modified: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.categoryID = categoryID
        self.created = created
        self.modified = modified ?? created
    }

    /// The title, or the first line of the body when there is no title.
    /// Reads only as far as that line, since it runs for every row and every search.
    public var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        guard let start = body.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        let end = body[start...].firstIndex(where: \.isNewline) ?? body.endIndex
        return String(body[start..<end].trimmingCharacters(in: .whitespaces).prefix(200))
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CategoryColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, gray
}

public struct PromptCategory: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: CategoryColor
    /// An SF Symbol name, or nil to show a plain dot.
    public var symbol: String?

    public init(id: UUID = UUID(), name: String, color: CategoryColor = .blue, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
    }
}

public enum LibraryError: Error, Equatable {
    case newerVersion(Int)
}

/// The whole library. Array order is display order.
public struct Library: Equatable, Sendable {
    public static let version = 1

    public var categories: [PromptCategory]
    public var prompts: [Prompt]

    public init(categories: [PromptCategory] = [], prompts: [Prompt] = []) {
        self.categories = categories
        self.prompts = prompts
        normalize()
    }

    public func prompt(_ id: UUID?) -> Prompt? {
        prompts.first { $0.id == id }
    }

    public func category(_ id: UUID?) -> PromptCategory? {
        categories.first { $0.id == id }
    }

    /// Prompts in a category, or all prompts for nil.
    public func prompts(in category: UUID?) -> [Prompt] {
        guard let category else { return prompts }
        return prompts.filter { $0.categoryID == category }
    }

    /// The first color no category uses yet.
    public var nextColor: CategoryColor {
        let used = Set(categories.map(\.color))
        let all = CategoryColor.allCases
        return all.first { !used.contains($0) } ?? all[categories.count % all.count]
    }

    // MARK: Changes

    public mutating func insert(_ prompt: Prompt) {
        prompts.insert(prompt, at: 0)
    }

    public mutating func update(_ id: UUID, _ change: (inout Prompt) -> Void) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        var prompt = prompts[index]
        change(&prompt)
        guard prompt != prompts[index] else { return }
        prompt.modified = .now
        prompts[index] = prompt
    }

    public mutating func removePrompts(_ ids: Set<UUID>) {
        prompts.removeAll { ids.contains($0.id) }
    }

    public mutating func movePrompts(_ ids: Set<UUID>, to category: UUID?) {
        guard category == nil || self.category(category) != nil else { return }
        for id in ids {
            update(id) { $0.categoryID = category }
        }
    }

    /// Moves prompts so they sit right before `target`, or at the end when target is nil.
    public mutating func reorderPrompts(_ ids: [UUID], before target: UUID?) {
        reorder(&prompts, ids, before: target)
    }

    public mutating func updateCategory(_ id: UUID, _ change: (inout PromptCategory) -> Void) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        change(&categories[index])
    }

    /// Removes a category. Its prompts stay in the library, uncategorized.
    public mutating func removeCategory(_ id: UUID) {
        categories.removeAll { $0.id == id }
        for index in prompts.indices where prompts[index].categoryID == id {
            prompts[index].categoryID = nil
        }
    }

    public mutating func reorderCategories(_ ids: [UUID], before target: UUID?) {
        reorder(&categories, ids, before: target)
    }

    private func reorder<Item: Identifiable>(_ items: inout [Item], _ ids: [UUID], before target: UUID?)
    where Item.ID == UUID {
        let moving = Set(ids)
        guard !moving.isEmpty, target.map({ !moving.contains($0) }) ?? true else { return }
        let picked = items.filter { moving.contains($0.id) }
        items.removeAll { moving.contains($0.id) }
        let index = target.flatMap { id in items.firstIndex { $0.id == id } } ?? items.endIndex
        items.insert(contentsOf: picked, at: index)
    }

    /// Repairs anything a hand edited file could get wrong.
    private mutating func normalize() {
        var seen = Set<UUID>()
        for index in categories.indices {
            if !seen.insert(categories[index].id).inserted { categories[index].id = UUID() }
            if categories[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                categories[index].name = "Untitled"
            }
            if categories[index].symbol?.isEmpty == true { categories[index].symbol = nil }
        }
        let categoryIDs = seen
        for index in prompts.indices {
            if !seen.insert(prompts[index].id).inserted { prompts[index].id = UUID() }
            if let id = prompts[index].categoryID, !categoryIDs.contains(id) { prompts[index].categoryID = nil }
        }
    }
}

// MARK: Coding

extension Library: Codable {
    private enum Keys: String, CodingKey { case version, categories, prompts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
        guard version <= Self.version else { throw LibraryError.newerVersion(version) }
        let categories = try container.decodeIfPresent([Lossy<PromptCategory>].self, forKey: .categories) ?? []
        let prompts = try container.decodeIfPresent([Lossy<Prompt>].self, forKey: .prompts) ?? []
        self.init(categories: categories.compactMap(\.value),
                  prompts: prompts.compactMap(\.value).filter { !$0.isEmpty })
    }

    /// Empty prompts only exist while being written, so they are never stored.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(categories, forKey: .categories)
        try container.encode(prompts.filter { !$0.isEmpty }, forKey: .prompts)
    }
}

extension PromptCategory: Codable {
    private enum Keys: String, CodingKey { case id, name, color, symbol }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(id: container.lenient(UUID.self, .id) ?? UUID(),
                  name: container.lenient(String.self, .name) ?? "",
                  color: container.lenient(String.self, .color).flatMap(CategoryColor.init) ?? .blue,
                  symbol: container.lenient(String.self, .symbol))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(symbol, forKey: .symbol)
    }
}

extension Prompt: Codable {
    private enum Keys: String, CodingKey { case id, title, body, category, created, modified }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let created = container.lenient(Date.self, .created) ?? .now
        self.init(id: container.lenient(UUID.self, .id) ?? UUID(),
                  title: container.lenient(String.self, .title) ?? "",
                  body: container.lenient(String.self, .body) ?? "",
                  categoryID: container.lenient(UUID.self, .category),
                  created: created,
                  modified: container.lenient(Date.self, .modified) ?? created)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(categoryID, forKey: .category)
        try container.encode(created, forKey: .created)
        try container.encode(modified, forKey: .modified)
    }
}

/// Decodes to nil instead of failing the whole array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
