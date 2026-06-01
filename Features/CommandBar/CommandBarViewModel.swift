import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CommandBarViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0
    @Published var droppedFiles: [URL] = []

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

    func addDroppedFile(_ url: URL) {
        guard !droppedFiles.contains(url) else { return }
        droppedFiles.append(url)
    }

    func removeDroppedFile(_ url: URL) {
        droppedFiles.removeAll { $0 == url }
    }

    /// Handles file drops from the command bar. Returns true if at least one file was accepted.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let fileURL = item as? URL {
                        url = fileURL
                    } else if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        self.addDroppedFile(url)
                    }
                }
            }
        }
        return accepted
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
        if !trimmed.isEmpty || !droppedFiles.isEmpty {
            await orchestrator?.planAndRun(query: trimmed.isEmpty ? "Use attached file" : query, attachedFiles: droppedFiles)
        }
    }
}
