import Foundation
import Testing
@testable import OutboundCore

struct ImportTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try write("Prompts/Loose.txt", "  Loose prompt \n")
        try write("Prompts/Code/Review.md", "Review this diff.")
        try write("Prompts/Code/Deep/Explain.md", "Explain this.")
        try write("Prompts/Writing/Email.txt", "Polish this email.")
        try write("Prompts/Writing/Empty.txt", " \n")
        try write("Prompts/.Hidden.txt", "hidden")
        try FileManager.default.createDirectory(at: folder.appending(path: "Prompts/Images"), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: folder.appending(path: "Prompts/Images/Logo.png"))
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func readsFoldersAsCategories() {
        let imported = PromptImport.read([folder.appending(path: "Prompts")])
        #expect(imported == [
            ImportedPrompt(title: "Explain", body: "Explain this.", category: "Code"),
            ImportedPrompt(title: "Review", body: "Review this diff.", category: "Code"),
            ImportedPrompt(title: "Loose", body: "Loose prompt", category: nil),
            ImportedPrompt(title: "Email", body: "Polish this email.", category: "Writing")
        ])
    }

    @Test func readsSingleFilesWithoutCategory() {
        let imported = PromptImport.read([folder.appending(path: "Prompts/Code/Review.md")])
        #expect(imported == [ImportedPrompt(title: "Review", body: "Review this diff.")])
    }

    @Test func addingReusesCategoriesAndSkipsDuplicates() {
        let code = PromptCategory(name: "code", color: .red)
        var library = Library(categories: [code], prompts: [Prompt(title: "Old", body: "x")])
        let imported = [
            ImportedPrompt(title: "A", body: "a", category: "Code"),
            ImportedPrompt(title: "B", body: "b", category: "Writing"),
            ImportedPrompt(title: "Old", body: "x"),
            ImportedPrompt(title: "A", body: "a", category: "Code")
        ]
        #expect(library.add(imported) == 2)
        #expect(library.prompts.map(\.title) == ["A", "B", "Old"])
        #expect(library.categories.map(\.name) == ["code", "Writing"])
        #expect(library.prompts[0].categoryID == code.id)
        #expect(library.add(imported) == 0)
    }
}
