import Foundation
import Testing
@testable import OutboundCore

struct LibraryTests {
    @Test func displayTitleFallsBackToFirstLine() {
        #expect(Prompt(title: "  Review ", body: "x").displayTitle == "Review")
        #expect(Prompt(body: "\n\n  You are a careful editor.\nMore").displayTitle == "You are a careful editor.")
        #expect(Prompt().displayTitle == "")
        #expect(Prompt(body: " \n ").isEmpty)
    }

    @Test func newPromptsGoOnTop() {
        var library = Library(prompts: [Prompt(title: "Old")])
        library.insert(Prompt(title: "New"))
        #expect(library.prompts.map(\.title) == ["New", "Old"])
    }

    @Test func updateTouchesModifiedOnlyOnChange() {
        let date = Date(timeIntervalSince1970: 0)
        var library = Library(prompts: [Prompt(title: "A", created: date)])
        let id = library.prompts[0].id
        library.update(id) { $0.title = "A" }
        #expect(library.prompts[0].modified == date)
        library.update(id) { $0.title = "B" }
        #expect(library.prompts[0].modified > date)
    }

    @Test func reorderMovesBeforeTarget() {
        let prompts = ["A", "B", "C", "D"].map { Prompt(title: $0) }
        var library = Library(prompts: prompts)
        library.reorderPrompts([prompts[3].id], before: prompts[1].id)
        #expect(library.prompts.map(\.title) == ["A", "D", "B", "C"])
        library.reorderPrompts([prompts[0].id], before: nil)
        #expect(library.prompts.map(\.title) == ["D", "B", "C", "A"])
        library.reorderPrompts([prompts[1].id], before: prompts[1].id)
        #expect(library.prompts.map(\.title) == ["D", "B", "C", "A"])
    }

    @Test func removingCategoryKeepsItsPrompts() {
        let category = PromptCategory(name: "Code")
        var library = Library(categories: [category], prompts: [Prompt(title: "A", categoryID: category.id)])
        library.removeCategory(category.id)
        #expect(library.categories.isEmpty)
        #expect(library.prompts.count == 1)
        #expect(library.prompts[0].categoryID == nil)
    }

    @Test func movingToMissingCategoryDoesNothing() {
        var library = Library(prompts: [Prompt(title: "A")])
        library.movePrompts([library.prompts[0].id], to: UUID())
        #expect(library.prompts[0].categoryID == nil)
    }

    @Test func nextColorPrefersUnused() {
        var library = Library()
        #expect(library.nextColor == .red)
        library.categories.append(PromptCategory(name: "A", color: .red))
        #expect(library.nextColor == .orange)
    }

    @Test func roundTripsThroughJSON() throws {
        let category = PromptCategory(name: "Code", color: .green, symbol: "terminal")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let library = Library(categories: [category], prompts: [
            Prompt(title: "B", body: "two", categoryID: category.id, created: date),
            Prompt(title: "A", body: "one", created: date)
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Library.self, from: encoder.encode(library)) == library)
    }

    @Test func decodesHandEditedFiles() throws {
        let id = UUID()
        let json = """
        {
          "categories": [
            {"id": "\(id)", "name": "Code", "color": "chartreuse", "symbol": ""},
            {"id": "\(id)", "name": "  "},
            42
          ],
          "prompts": [
            {"body": "no id"},
            {"id": "\(id)", "title": "dangling", "category": "\(UUID())"},
            {"title": "kept", "category": "\(id)", "created": "not a date"},
            {"title": " ", "body": ""},
            "junk"
          ]
        }
        """
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(library.categories.count == 2)
        #expect(library.categories[0].color == .blue)
        #expect(library.categories[0].symbol == nil)
        #expect(library.categories[1].name == "Untitled")
        #expect(library.categories[1].id != id)
        #expect(Set(library.categories.map(\.id) + library.prompts.map(\.id)).count == 5)
        #expect(library.prompts.map(\.title) == ["", "dangling", "kept"])
        #expect(library.prompts[1].categoryID == nil)
        #expect(library.prompts[2].categoryID == id)
    }

    @Test func neverStoresEmptyPrompts() throws {
        let library = Library(prompts: [Prompt(), Prompt(title: "A")])
        let decoded = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        #expect(decoded.prompts.map(\.title) == ["A"])
    }

    @Test func rejectsNewerVersions() {
        #expect(throws: LibraryError.newerVersion(2)) {
            try JSONDecoder().decode(Library.self, from: Data(#"{"version": 2}"#.utf8))
        }
    }
}
