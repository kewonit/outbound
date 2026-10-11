import Testing
@testable import OutboundCore

struct SearchTests {
    let prompts = [
        Prompt(title: "Summarize thread", body: "Summarize this conversation in three bullets."),
        Prompt(title: "Code review", body: "Review this diff for bugs."),
        Prompt(title: "Résumé polish", body: "Tighten the wording."),
        Prompt(title: "Rewrite concisely", body: "Make it shorter. Keep the code blocks."),
        Prompt(body: "Translate the following into French.")
    ]

    func titles(_ query: String) -> [String] {
        var search = Search()
        return search.results(for: query, in: prompts).map(\.displayTitle)
    }

    @Test func emptyQueryKeepsLibraryOrder() {
        #expect(titles("  ") == prompts.map(\.displayTitle))
    }

    @Test func titleBeatsBody() {
        #expect(titles("code") == ["Code review", "Rewrite concisely"])
    }

    @Test func prefixBeatsWordPrefixBeatsSubstring() {
        let prompts = [Prompt(title: "Unreviewed"), Prompt(title: "Code review"), Prompt(title: "Review")]
        var search = Search()
        #expect(search.results(for: "review", in: prompts).map(\.title) == ["Review", "Code review", "Unreviewed"])
    }

    @Test func everyWordMustMatch() {
        #expect(titles("review bugs") == ["Code review"])
        #expect(titles("review french").isEmpty)
    }

    @Test func ignoresCaseAndAccents() {
        #expect(titles("RESUME") == ["Résumé polish"])
    }

    @Test func matchesLooseAbbreviations() {
        #expect(titles("cdrv") == ["Code review"])
    }

    @Test func untitledPromptsMatchTheirFirstLine() {
        #expect(titles("translate") == ["Translate the following into French."])
    }

    @Test func exactTitleWins() {
        let prompts = [Prompt(title: "Review code"), Prompt(title: "Review")]
        var search = Search()
        #expect(search.results(for: "review", in: prompts).first?.title == "Review")
    }

    @Test func seesEdits() {
        var search = Search()
        var prompt = Prompt(title: "Alpha")
        #expect(search.results(for: "beta", in: [prompt]).isEmpty)
        prompt.title = "Beta"
        #expect(search.results(for: "beta", in: [prompt]).count == 1)
    }
}
