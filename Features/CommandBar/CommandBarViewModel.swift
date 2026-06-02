import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CommandBarViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var followUpQuery: String = ""
    @Published var selectedIndex: Int = 0
    @Published var droppedFiles: [URL] = []
    @Published var isProcessing: Bool = false
    @Published var processingStatus: String = ""
    @Published var hasConversation: Bool = false

    private weak var orchestrator: CommandOrchestrator?
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func bind(orchestrator: CommandOrchestrator) {
        self.orchestrator = orchestrator
        bindLifecycleUpdates(orchestrator: orchestrator)
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

    var inputPlaceholder: String {
        hasConversation
            ? "Ask a follow-up…"
            : "Ask Oopla to do anything on your Mac..."
    }

    var hasPendingFollowUpText: Bool {
        !followUpQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if trimmed.isEmpty && droppedFiles.isEmpty { return }

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
        let finalQuery = trimmed.isEmpty ? "Use attached file" : query
        guard let orchestrator else { return }

        // Instant user feedback when Enter is pressed.
        isProcessing = true
        processingStatus = "Thinking…"

        if hasConversation {
            await orchestrator.continueConversation(query: finalQuery, attachedFiles: droppedFiles)
        } else {
            await orchestrator.planAndRun(query: finalQuery, attachedFiles: droppedFiles)
            // Move the same text into follow-up input once conversation starts.
            followUpQuery = ""
        }
    }

    func submitFollowUp() async {
        let text = followUpQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = text
        await executeCurrentSelection(results: [])
        followUpQuery = ""
    }

    func startNewConversation() {
        orchestrator?.clearConversation()
        query = ""
        followUpQuery = ""
        selectedIndex = 0
        droppedFiles = []
        processingStatus = ""
        isProcessing = false
        hasConversation = false
        onQueryChanged()
    }

    // MARK: - Processing lifecycle

    private func bindLifecycleUpdates(orchestrator: CommandOrchestrator) {
        cancellables.removeAll()

        orchestrator.$executionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let status = state.statusLine
                if status.isEmpty { return }

                if status.localizedCaseInsensitiveContains("Analyzing screen") {
                    self.processingStatus = "Analyzing screen…"
                } else if status.localizedCaseInsensitiveContains("planning")
                            || status.localizedCaseInsensitiveContains("planned") {
                    self.processingStatus = "Planning…"
                } else if status.localizedCaseInsensitiveContains("executing")
                            || status.localizedCaseInsensitiveContains("running") {
                    self.processingStatus = "Running…"
                } else {
                    self.processingStatus = status
                }

                if Self.isTerminalStatus(status) {
                    self.isProcessing = false
                }
            }
            .store(in: &cancellables)

        orchestrator.$conversation
            .receive(on: RunLoop.main)
            .sink { [weak self] turns in
                self?.hasConversation = !turns.isEmpty
            }
            .store(in: &cancellables)

        orchestrator.$latestError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.isProcessing = false
                    self.processingStatus = "Failed."
                }
            }
            .store(in: &cancellables)
    }

    private static func isTerminalStatus(_ status: String) -> Bool {
        let s = status.lowercased()
        return s == "done."
            || s == "cancelled."
            || s.contains("failed")
            || s.contains("execution stopped")
            || s.contains("confirmation required")
    }
}
