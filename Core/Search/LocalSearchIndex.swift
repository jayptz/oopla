import AppKit
import Foundation

final class LocalSearchIndex: SearchProviding {
    private let fileManager = FileManager.default
    private let maxPerRoot = 200

    func search(query: String) async -> [SearchResultItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return recentSuggestions()
        }

        async let appResults = searchApps(query: query)
        async let fileResults = searchFiles(query: query)
        async let actionResults = suggestActions(query: query)

        let merged = await appResults + fileResults + actionResults
        return merged.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }

    private func searchApps(query: String) async -> [SearchResultItem] {
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]

        var results: [SearchResultItem] = []
        for dir in appDirs {
            guard let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                if fuzzyMatch(query: query, target: name) {
                    results.append(
                        SearchResultItem(
                            title: name,
                            subtitle: "Application",
                            kind: .app,
                            path: url.path,
                            score: score(query: query, target: name)
                        )
                    )
                }
            }
        }
        return results.prefix(5).map { $0 }
    }

    private func searchFiles(query: String) async -> [SearchResultItem] {
        let roots = [
            fileManager.homeDirectoryForCurrentUser.appending(path: "Desktop"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Documents"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Downloads")
        ]
        var results: [SearchResultItem] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var scanned = 0
            while let url = enumerator.nextObject() as? URL, scanned < maxPerRoot {
                scanned += 1
                let name = url.lastPathComponent
                if fuzzyMatch(query: query, target: name) {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                    let isDirectory = values?.isDirectory ?? false
                    let modified = values?.contentModificationDate?.formatted() ?? "Unknown"
                    results.append(
                        SearchResultItem(
                            title: name,
                            subtitle: "\(isDirectory ? "Folder" : "File") • Modified \(modified)",
                            kind: isDirectory ? .folder : .file,
                            path: url.path,
                            score: score(query: query, target: name)
                        )
                    )
                }
            }
        }
        return results.sorted { $0.score > $1.score }.prefix(7).map { $0 }
    }

    private func suggestActions(query: String) async -> [SearchResultItem] {
        var items: [SearchResultItem] = []
        if query.localizedCaseInsensitiveContains("open ") {
            items.append(SearchResultItem(title: "AI: \(query)", subtitle: "Run as agent action", kind: .aiAction, score: 0.97))
        }
        if query.localizedCaseInsensitiveContains("folder") {
            items.append(SearchResultItem(title: "Create folder from command", subtitle: "Agent will ask for confirmation", kind: .aiAction, score: 0.95))
        }
        if query.localizedCaseInsensitiveContains("search ") || query.localizedCaseInsensitiveContains("google ") {
            items.append(SearchResultItem(title: "Search web for \(query)", subtitle: "Open browser with search", kind: .action, score: 0.8))
        }
        return items
    }

    private func recentSuggestions() -> [SearchResultItem] {
        [
            SearchResultItem(title: "Open Spotify", subtitle: "Recent command", kind: .aiAction, score: 0.6),
            SearchResultItem(title: "Find my latest resume", subtitle: "Recent command", kind: .aiAction, score: 0.59),
            SearchResultItem(title: "Create folder on Desktop", subtitle: "Recent command", kind: .aiAction, score: 0.58)
        ]
    }

    private func fuzzyMatch(query: String, target: String) -> Bool {
        target.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains(target)
    }

    private func score(query: String, target: String) -> Double {
        let q = query.lowercased()
        let t = target.lowercased()
        if t == q { return 1.0 }
        if t.hasPrefix(q) { return 0.95 }
        if t.contains(q) { return 0.85 }
        return 0.5
    }
}
