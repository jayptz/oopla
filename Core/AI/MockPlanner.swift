import Foundation

enum PlannerError: Error {
    case invalidPlan
}

final class MockPlanner: PlannerProviding {
    func createPlan(for query: String, candidates: [SearchResultItem]) async throws -> ActionPlan {
        let q = query.lowercased()

        if q.contains("open chrome") && q.contains("youtube") {
            return ActionPlan(
                userQuery: query,
                summary: "Launch Chrome and open YouTube.",
                steps: [
                    ToolCall(toolName: "app_launcher_tool", arguments: ["appName": "Google Chrome"], reason: "Need browser."),
                    ToolCall(toolName: "browser_open_url_tool", arguments: ["url": "https://www.youtube.com"], reason: "Open requested site.")
                ]
            )
        }

        if q.contains("open spotify") {
            return ActionPlan(
                userQuery: query,
                summary: "Launch Spotify app.",
                steps: [
                    ToolCall(toolName: "app_launcher_tool", arguments: ["appName": "Spotify"], reason: "User asked to open Spotify.")
                ]
            )
        }

        if q.contains("create") && q.contains("folder") {
            let folderName = extractQuotedOrTrailingName(query: query, marker: "called") ?? "New Folder"
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop").path
            return ActionPlan(
                userQuery: query,
                summary: "Create a folder on Desktop.",
                steps: [
                    ToolCall(toolName: "folder_create_tool", arguments: ["path": "\(desktop)/\(folderName)"], reason: "Create requested folder.")
                ],
                requiresConfirmation: true
            )
        }

        if q.contains("find") && q.contains("resume") {
            return ActionPlan(
                userQuery: query,
                summary: "Find your resume and open it.",
                steps: [
                    ToolCall(toolName: "file_search_tool", arguments: ["query": "resume"], reason: "Locate resume."),
                    ToolCall(toolName: "file_open_tool", arguments: ["path": candidates.first(where: { $0.kind == .file })?.path ?? ""], reason: "Open likely match.")
                ]
            )
        }

        if let appCandidate = candidates.first(where: { $0.kind == .app }), q.contains("open") {
            return ActionPlan(
                userQuery: query,
                summary: "Open \(appCandidate.title).",
                steps: [
                    ToolCall(toolName: "app_launcher_tool", arguments: ["appName": appCandidate.title], reason: "Best app match.")
                ]
            )
        }

        if q.contains("search") || q.contains("google") {
            let clean = query.replacingOccurrences(of: "search", with: "").trimmingCharacters(in: .whitespaces)
            return ActionPlan(
                userQuery: query,
                summary: "Search web query.",
                steps: [
                    ToolCall(toolName: "web_search_tool", arguments: ["query": clean], reason: "Open web search.")
                ]
            )
        }

        // Fallback: if a direct file result exists, open it.
        if let firstFile = candidates.first(where: { $0.kind == .file || $0.kind == .folder }), let path = firstFile.path {
            return ActionPlan(
                userQuery: query,
                summary: "Open top local result.",
                steps: [
                    ToolCall(toolName: "file_open_tool", arguments: ["path": path], reason: "Best local match.")
                ]
            )
        }

        throw PlannerError.invalidPlan
    }

    private func extractQuotedOrTrailingName(query: String, marker: String) -> String? {
        if let start = query.range(of: "\""), let end = query.range(of: "\"", range: start.upperBound..<query.endIndex) {
            return String(query[start.upperBound..<end.lowerBound])
        }
        guard let markerRange = query.lowercased().range(of: marker) else { return nil }
        return query[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct StubAIProvider: AIProvider {
    let providerName: String = "Stub"
    func structuredPlan(prompt: String, schema: String) async throws -> String {
        """
        {"summary":"stub","steps":[]}
        """
    }
}
