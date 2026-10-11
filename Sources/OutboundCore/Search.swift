import Foundation

/// Ranks prompts against a query. Every word of the query has to match.
/// Title matches beat body matches, and library order breaks ties.
public struct Search {
    private struct Entry {
        let title: String
        let body: String
        let words: [Substring]
        let source: (title: String, body: String)
    }

    private var cache: [UUID: Entry] = [:]

    public init() {}

    public mutating func results(for query: String, in prompts: [Prompt]) -> [Prompt] {
        let tokens = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return prompts }
        let phrase = tokens.joined(separator: " ")

        var ranked: [(score: Int, index: Int, prompt: Prompt)] = []
        for (index, prompt) in prompts.enumerated() {
            let entry = entry(for: prompt)
            var total = entry.title == phrase ? 1000 : 0
            for token in tokens {
                guard let score = Self.score(token, entry) else { total = -1; break }
                total += score
            }
            if total >= 0 { ranked.append((total, index, prompt)) }
        }
        if cache.count > prompts.count * 2 { prune(keeping: prompts) }
        return ranked
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.prompt)
    }

    private static func score(_ token: String, _ entry: Entry) -> Int? {
        if entry.title.hasPrefix(token) { return 100 }
        if entry.words.contains(where: { $0.hasPrefix(token) }) { return 80 }
        if entry.title.contains(token) { return 60 }
        if token.count > 1, isLooseMatch(token, entry) { return 30 }
        if entry.body.contains(token) { return 10 }
        return nil
    }

    /// Letters in order, starting at a word: "cdrv" finds "Code review", "re" does not find "Write".
    private static func isLooseMatch(_ token: String, _ entry: Entry) -> Bool {
        guard let start = entry.words.first(where: { $0.first == token.first })?.startIndex else { return false }
        var remaining = token.dropFirst()
        for character in entry.title[start...] where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    private mutating func entry(for prompt: Prompt) -> Entry {
        let title = prompt.displayTitle
        if let entry = cache[prompt.id], entry.source.title == title, entry.source.body == prompt.body {
            return entry
        }
        let folded = Self.fold(title)
        let entry = Entry(title: folded,
                          body: Self.fold(prompt.body),
                          words: folded.split { !$0.isLetter && !$0.isNumber },
                          source: (title, prompt.body))
        cache[prompt.id] = entry
        return entry
    }

    private mutating func prune(keeping prompts: [Prompt]) {
        let ids = Set(prompts.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
