import Foundation

/// Reads and writes the library as a single JSON file.
public final class LibraryStore {
    public let url: URL
    private var lastWrite: Date?

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Outbound", "Library.json")
    }

    public struct Loaded {
        public var library: Library
        /// Where an unreadable file was moved, if it was.
        public var movedAside: URL?
    }

    /// Loads the library. A missing file is an empty library. A damaged file is
    /// moved aside so nothing is lost, and an empty library is returned.
    public func load() throws -> Loaded {
        let file = target
        guard FileManager.default.fileExists(atPath: file.path) else {
            lastWrite = nil
            return Loaded(library: Library())
        }
        let data = try Data(contentsOf: file)
        lastWrite = modificationDate
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return Loaded(library: Library())
        }
        do {
            return Loaded(library: try Self.decoder.decode(Library.self, from: data))
        } catch let error as LibraryError {
            throw error
        } catch {
            let aside = file.deletingLastPathComponent().appending(path: Self.asideName())
            try FileManager.default.moveItem(at: file, to: aside)
            lastWrite = nil
            return Loaded(library: Library(), movedAside: aside)
        }
    }

    public func save(_ library: Library) throws {
        let file = target
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(library).write(to: file, options: .atomic)
        lastWrite = modificationDate
    }

    /// True when something other than this store changed the file since it was last read or written.
    public var changedElsewhere: Bool {
        modificationDate != lastWrite
    }

    /// The real file, so a symlinked library keeps its link when saved.
    private var target: URL {
        url.resolvingSymlinksInPath()
    }

    private var modificationDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
    }

    private static func asideName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Library \(formatter.string(from: .now)).damaged.json"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
