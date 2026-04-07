import Foundation

@MainActor
final class CommandBarViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0

    private weak var orchestrator: CommandOrchestrator?
    private var searchTask: Task<Void, Never>?

    func bind(orchestrator: CommandOrchestrator) {
        self.orchestrator = orchestrator
    }

    func onQueryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let orchestrator else { return }
            await orchestrator.updateSearch(for: query)
            selectedIndex = 0
        }
    }

    func executeCurrentSelection(results: [SearchResultItem]) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !results.isEmpty, selectedIndex < results.count {
            let selected = results[selectedIndex]
            switch selected.kind {
            case .app:
                query = "open \(selected.title)"
            case .file, .folder:
                query = "open \(selected.title)"
            case .action, .aiAction, .web:
                break
            }
        }
        if !trimmed.isEmpty {
            await orchestrator?.planAndRun(query: query)
        }
    }
}
