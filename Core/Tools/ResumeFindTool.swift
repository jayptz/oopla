import AppKit
import Foundation

// MARK: - ResumeFindTool

struct ResumeFindTool: ToolProtocol {
    private static var activeSpotlight: ResumeSpotlightQuery?

    let name = "resume_find_tool"
    let description = "Searches the Mac for resume/CV files and returns up to 5 matches, newest first."
    let inputSchema: [String: String] = [:]
    let resultSchema = [
        "resume1Path": "String",
        "resume1Name": "String",
        "resume1Modified": "String"
    ]
    let safetyLevel: SafetyLevel = .safe

    fileprivate static let nameKeywords = ["resume", "cv", "curriculum"]
    private static let allowedExtensions: Set<String> = ["pdf", "docx", "txt", "md", "pages"]

    func execute(arguments: [String: String]) async throws -> ToolResult {
        async let spotlightHits = spotlightResumeSearch()
        let folderHits        = searchHomeFolders()

        var seen = Set<String>()
        var matches: [(url: URL, modified: Date)] = []

        for url in await spotlightHits + folderHits {
            guard seen.insert(url.path).inserted else { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.allowedExtensions.contains(ext) else { continue }
            guard Self.matchesResumeName(url.lastPathComponent) else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            matches.append((url: url, modified: modified))
        }

        matches.sort { $0.modified > $1.modified }
        let top = matches.prefix(5)

        guard !top.isEmpty else {
            return ToolResult(
                toolName: name,
                success: false,
                message: "No resume files found. Try naming a file with 'resume' or 'cv' in the title.",
                payload: [:]
            )
        }

        var payload: [String: String] = [:]
        let formatter = ISO8601DateFormatter()
        for (i, item) in top.enumerated() {
            let n = i + 1
            payload["resume\(n)Path"]     = item.url.path
            payload["resume\(n)Name"]     = item.url.lastPathComponent
            payload["resume\(n)Modified"] = formatter.string(from: item.modified)
        }
        // Convenience key for downstream file_read_tool.
        if let first = payload["resume1Path"] {
            payload["bestPath"] = first
        }

        return ToolResult(
            toolName: name,
            success: true,
            message: "Found \(top.count) resume file(s).",
            payload: payload
        )
    }

    // MARK: - Search helpers

    private static func matchesResumeName(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return nameKeywords.contains { lower.contains($0) }
    }

    private func searchHomeFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Documents", "Desktop", "Downloads"].map { home.appendingPathComponent($0) }
        var results: [URL] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var scanned = 0
            while let url = enumerator.nextObject() as? URL, scanned < 500 {
                scanned += 1
                guard Self.matchesResumeName(url.lastPathComponent) else { continue }
                results.append(url)
            }
        }
        return results
    }

    private func spotlightResumeSearch() async -> [URL] {
        Self.activeSpotlight?.cancel()
        Self.activeSpotlight = nil

        return await withCheckedContinuation { continuation in
            let query = ResumeSpotlightQuery { urls in
                Self.activeSpotlight = nil
                continuation.resume(returning: urls)
            }
            Self.activeSpotlight = query
            query.start()
        }
    }
}

// MARK: - Spotlight helper

private final class ResumeSpotlightQuery {
    private let mdQuery = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var finished = false
    private let onComplete: ([URL]) -> Void

    init(onComplete: @escaping ([URL]) -> Void) {
        self.onComplete = onComplete
    }

    deinit {
        cancel()
    }

    func cancel() {
        finish(with: [])
    }

    func start() {
        // OR predicate across resume keywords in display name.
        let preds = ResumeFindTool.nameKeywords.map {
            NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, $0)
        }
        mdQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: preds)
        mdQuery.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        mdQuery.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemContentModificationDateKey, ascending: false)
        ]

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mdQuery,
            queue: .main
        ) { [weak self] _ in
            self?.finish(with: self?.gatherURLs() ?? [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish(with: self?.gatherURLs() ?? [])
        }

        DispatchQueue.main.async { [weak self] in
            self?.mdQuery.start()
        }
    }

    private func finish(with urls: [URL]) {
        guard !finished else { return }
        finished = true
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        if mdQuery.isStarted {
            mdQuery.stop()
        }
        onComplete(urls)
    }

    private func gatherURLs() -> [URL] {
        var urls: [URL] = []
        mdQuery.disableUpdates()
        let count = min(mdQuery.resultCount, 20)
        for i in 0..<count {
            guard let item = mdQuery.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        mdQuery.enableUpdates()
        return urls
    }
}
