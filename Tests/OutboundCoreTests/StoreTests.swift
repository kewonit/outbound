import Foundation
import Testing
@testable import OutboundCore

struct StoreTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func missingFileIsEmptyLibrary() throws {
        let store = LibraryStore(url: folder.appending(components: "Nested", "Library.json"))
        #expect(try store.load().library == Library())
        try store.save(Library(prompts: [Prompt(title: "A")]))
        #expect(try store.load().library.prompts.map(\.title) == ["A"])
    }

    @Test func damagedFileIsMovedAside() throws {
        let url = folder.appending(path: "Library.json")
        try Data("{ not json".utf8).write(to: url)
        let loaded = try LibraryStore(url: url).load()
        #expect(loaded.library == Library())
        let aside = try #require(loaded.movedAside)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func blankFileIsEmptyLibrary() throws {
        let url = folder.appending(path: "Library.json")
        try Data(" \n".utf8).write(to: url)
        let loaded = try LibraryStore(url: url).load()
        #expect(loaded.library == Library())
        #expect(loaded.movedAside == nil)
    }

    @Test func newerVersionIsLeftAlone() throws {
        let url = folder.appending(path: "Library.json")
        try Data(#"{"version": 9}"#.utf8).write(to: url)
        #expect(throws: LibraryError.newerVersion(9)) { try LibraryStore(url: url).load() }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func savingKeepsSymlink() throws {
        let real = folder.appending(path: "Synced.json")
        let link = folder.appending(path: "Library.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try LibraryStore(url: link).save(Library(prompts: [Prompt(title: "A")]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try LibraryStore(url: real).load().library.prompts.map(\.title) == ["A"])
    }

    @Test func noticesOutsideChanges() throws {
        let url = folder.appending(path: "Library.json")
        let store = LibraryStore(url: url)
        try store.save(Library())
        #expect(!store.changedElsewhere)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: url.path)
        #expect(store.changedElsewhere)
        _ = try store.load()
        #expect(!store.changedElsewhere)
    }
}
