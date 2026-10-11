import Foundation

/// A prompt read from a text file. Files inside a subfolder of a chosen folder
/// carry that subfolder's name as their category.
public struct ImportedPrompt: Equatable, Sendable {
    public var title: String
    public var body: String
    public var category: String?

    public init(title: String, body: String, category: String? = nil) {
        self.title = title
        self.body = body
        self.category = category
    }
}

public enum PromptImport {
    static let maxFileSize = 1_000_000

    /// Reads text files, and text files inside folders. Anything that isn't text is skipped.
    public static func read(_ urls: [URL]) -> [ImportedPrompt] {
        var result: [ImportedPrompt] = []
        for url in urls {
            let root = url.resolvingSymlinksInPath()
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                if let prompt = read(file: root, category: nil) { result.append(prompt) }
                continue
            }
            let depth = root.pathComponents.count
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL }
                .map { $0.resolvingSymlinksInPath() }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } ?? []
            for file in files {
                let folders = file.pathComponents.dropFirst(depth).dropLast()
                if let prompt = read(file: file, category: folders.first) { result.append(prompt) }
            }
        }
        return result
    }

    private static func read(file: URL, category: String?) -> ImportedPrompt? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: file), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return ImportedPrompt(title: file.deletingPathExtension().lastPathComponent, body: body, category: category)
    }
}

extension Library {
    /// Adds imported prompts on top, creating categories by name as needed.
    /// Prompts already in the library are skipped. Returns how many were added.
    @discardableResult
    public mutating func add(_ imported: [ImportedPrompt]) -> Int {
        var seen = Set(prompts.map { [$0.title, $0.body] })
        var added: [Prompt] = []
        for item in imported where seen.insert([item.title, item.body]).inserted {
            let category = item.category.map { categoryID(named: $0) }
            added.append(Prompt(title: item.title, body: item.body, categoryID: category))
        }
        prompts.insert(contentsOf: added, at: 0)
        return added.count
    }

    private mutating func categoryID(named name: String) -> UUID {
        if let match = categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match.id
        }
        let category = PromptCategory(name: name, color: nextColor)
        categories.append(category)
        return category.id
    }
}
