import Foundation
import Observation
import OutboundCore

@MainActor
@Observable
final class Model {
    enum Mode: Equatable {
        case browse
        case prompt(UUID)
        case category(UUID)
    }

    enum Field: Hashable {
        case search, title, body, categoryName
    }

    struct FocusRequest: Equatable {
        var field: Field
        var count = 0
    }

    enum Problem {
        case movedAside(URL)
        case saveFailed(Error)
    }

    private(set) var library = Library()
    private(set) var results: [Prompt] = []
    private(set) var mode = Mode.browse
    private(set) var focusRequest = FocusRequest(field: .search)
    var selection: UUID?

    var query = "" {
        didSet { if query != oldValue { refresh(selectFirst: true) } }
    }

    /// The category being shown, or nil for all prompts.
    var scope: UUID? {
        didSet { if scope != oldValue { refresh(selectFirst: true) } }
    }

    @ObservationIgnored var onProblem: (Problem) -> Void = { _ in }
    /// Called when an editor closes, so its typing undo history can go with it.
    @ObservationIgnored var onLeaveEditor: () -> Void = {}
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var search = Search()
    @ObservationIgnored private var editBaseline: Library?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored private var saveFailing = false

    init(store: LibraryStore) {
        self.store = store
    }

    var libraryURL: URL { store.url }

    var selectedPrompt: Prompt? { library.prompt(selection) }

    // MARK: Loading and saving

    func load() throws {
        let loaded = try store.load()
        library = loaded.library
        refresh(selectFirst: true)
        if let aside = loaded.movedAside { onProblem(.movedAside(aside)) }
    }

    /// Picks up edits made to the file by something else, unless there is local work in flight.
    func reloadIfChangedElsewhere() throws {
        guard !unsaved, editBaseline == nil, store.changedElsewhere else { return }
        let loaded = try store.load()
        if let aside = loaded.movedAside {
            unsaved = true
            save()
            onProblem(.movedAside(aside))
        } else if loaded.library != library {
            library = loaded.library
            undoManager.removeAllActions()
            refresh()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard unsaved else { return }
        do {
            try store.save(library)
            unsaved = false
            saveFailing = false
        } catch {
            if !saveFailing { onProblem(.saveFailed(error)) }
            saveFailing = true
        }
    }

    private func scheduleSave() {
        unsaved = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: Browsing

    func focus(_ field: Field) {
        focusRequest = FocusRequest(field: field, count: focusRequest.count + 1)
    }

    /// Called each time the panel opens.
    func prepareToShow() {
        if mode == .browse {
            query = ""
            refresh(selectFirst: true)
            focus(.search)
        } else {
            focus(focusRequest.field)
        }
    }

    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : results.count)
        selection = results[max(0, min(results.count - 1, current + offset))].id
    }

    func selectEdge(last: Bool) {
        selection = last ? results.last?.id : results.first?.id
    }

    /// ⌘0 shows everything, ⌘1 to ⌘9 the categories in rail order.
    func selectScope(number: Int) {
        if number == 0 {
            scope = nil
        } else if library.categories.indices.contains(number - 1) {
            scope = library.categories[number - 1].id
        }
    }

    private func refresh(selectFirst: Bool = false) {
        if let scope, library.category(scope) == nil {
            self.scope = nil
            return
        }
        results = search.results(for: query, in: library.prompts(in: scope))
        if selectFirst || !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    // MARK: Editing

    /// Starts a prompt in the current category. A search in progress becomes its title.
    func newPrompt() {
        settle()
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = Prompt(title: title, categoryID: scope)
        editBaseline = library
        library.insert(prompt)
        query = ""
        selection = prompt.id
        mode = .prompt(prompt.id)
        focus(title.isEmpty ? .title : .body)
    }

    func edit(_ id: UUID) {
        guard library.prompt(id) != nil else { return }
        settle()
        selection = id
        mode = .prompt(id)
        focus(.body)
    }

    func setTitle(_ title: String, of id: UUID) {
        editPrompt(id) { $0.title = title }
    }

    func setBody(_ body: String, of id: UUID) {
        editPrompt(id) { $0.body = body }
    }

    private func editPrompt(_ id: UUID, _ change: (inout Prompt) -> Void) {
        if editBaseline == nil { editBaseline = library }
        library.update(id, change)
        refresh()
        scheduleSave()
    }

    /// Leaves an editor. A prompt left empty is discarded.
    func back() {
        guard case .prompt(let id) = mode else { return }
        if library.prompt(id)?.isEmpty == true {
            if editBaseline == nil { editBaseline = library }
            library.removePrompts([id])
            scheduleSave()
        }
        settle()
        mode = .browse
        onLeaveEditor()
        refresh()
        if results.contains(where: { $0.id == id }) { selection = id }
        focus(.search)
    }

    // MARK: Changes

    func delete(_ id: UUID) {
        let index = results.firstIndex { $0.id == id }
        change("Delete Prompt") { $0.removePrompts([id]) }
        if let index, !results.isEmpty {
            selection = results[min(index, results.count - 1)].id
        }
    }

    func undo() {
        settle()
        undoManager.undo()
    }

    func redo() {
        settle()
        undoManager.redo()
    }

    /// Applies a change as one undoable step.
    private func change(_ name: String, _ body: (inout Library) -> Void) {
        settle()
        var next = library
        body(&next)
        guard next != library else { return }
        let previous = library
        library = next
        registerUndo(restoring: previous, name: name)
        didChange()
    }

    /// Ends an editing session, recording everything typed in it as one undo step.
    private func settle() {
        guard let baseline = editBaseline else { return }
        editBaseline = nil
        if baseline != library { registerUndo(restoring: baseline, name: "Edit") }
    }

    private func registerUndo(restoring snapshot: Library, name: String) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: Library, name: String) {
        let current = library
        library = snapshot
        registerUndo(restoring: current, name: name)
        didChange()
    }

    private func didChange() {
        switch mode {
        case .prompt(let id) where library.prompt(id) == nil,
             .category(let id) where library.category(id) == nil:
            mode = .browse
            focus(.search)
        default:
            break
        }
        refresh()
        scheduleSave()
    }
}
