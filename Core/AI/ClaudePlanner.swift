import Foundation

// MARK: - Response Models

private struct ClaudeResponse: Decodable {
    let content: [ClaudeContentBlock]
}

private struct ClaudeContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct PlannedAction: Decodable {
    let toolName: String
    let arguments: [String: String]
    let reason: String
}

private struct ClaudePlan: Decodable {
    let summary: String
    let requiresConfirmation: Bool
    let steps: [PlannedAction]
}

// MARK: - ClaudePlanner

final class ClaudePlanner: PlannerProviding {

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
        self.session = URLSession.shared
    }

    func createPlan(for query: String, candidates: [SearchResultItem]) async throws -> ActionPlan {
        let prompt = buildPrompt(query: query, candidates: candidates)
        let json = try await callClaude(prompt: prompt)
        return try parsePlan(json: json, query: query)
    }

    // MARK: - Prompt

    private func buildPrompt(query: String, candidates: [SearchResultItem]) -> String {
        let candidateList = candidates.prefix(8).map { item in
            "- [\(item.kind.rawValue)] \(item.title)\(item.path.map { " (path: \($0))" } ?? "")"
        }.joined(separator: "\n")

        let tools = """
        app_launcher_tool        | args: appName (string)
        file_open_tool           | args: path (string)
        file_search_tool         | args: query (string)
        folder_create_tool       | args: path (string)          [confirmationRequired]
        browser_open_url_tool    | args: url (string)
        web_search_tool          | args: query (string)
        clipboard_write_tool     | args: text (string)
        clipboard_read_tool      | args: (none)
        finder_reveal_tool       | args: path (string)
        """

        return """
        You are Oopla, an AI command bar for macOS. Your job is to convert a user's natural language command into a structured action plan.

        Available tools:
        \(tools)

        Tool notes:
        - app_launcher_tool can launch ANY application installed on the user's Mac. \
        Pass the app's common display name exactly as the user would say it (e.g. "Spotify", \
        "Cursor", "Arc", "Warp", "VS Code", "Xcode", "Discord", "Notion", "Figma"). \
        The tool resolves common name variants automatically, so use natural names — \
        do not fabricate bundle identifiers or file paths for apps.
        - browser_open_url_tool opens a URL in the default browser. Use it for web destinations \
        (YouTube, Gmail, GitHub, etc.) rather than launching a browser app separately unless \
        the user specifically names a browser.
        - For "open <app> and go to <url>" commands, use app_launcher_tool first then \
        browser_open_url_tool for the URL.

        Local search candidates already found:
        \(candidateList.isEmpty ? "(none)" : candidateList)

        User command: "\(query)"

        Rules:
        - Use the local candidates when they are relevant (e.g. if user says "open my resume" and a resume file is in candidates, use file_open_tool with its path).
        - For multi-step commands (e.g. "open chrome and go to youtube"), produce multiple steps in order.
        - Set requiresConfirmation to true if any step creates, moves, deletes, or modifies files/folders.
        - Keep summary short (one sentence).
        - Only use tools from the list above.
        - All argument values must be strings.

        Respond ONLY with a valid JSON object in this exact format, no markdown, no explanation:
        {
          "summary": "short description of what you will do",
          "requiresConfirmation": false,
          "steps": [
            {
              "toolName": "tool_name_here",
              "arguments": { "argKey": "argValue" },
              "reason": "why this step"
            }
          ]
        }
        """
    }

    // MARK: - API Call

    private func callClaude(prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.invalidPlan
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClaudePlannerError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw PlannerError.invalidPlan
        }

        return text
    }

    // MARK: - Parse

    private func parsePlan(json: String, query: String) throws -> ActionPlan {
        // Strip any accidental markdown fences
        let cleaned = json
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw PlannerError.invalidPlan
        }

        let plan = try JSONDecoder().decode(ClaudePlan.self, from: data)

        let steps = plan.steps.map { action in
            ToolCall(
                toolName: action.toolName,
                arguments: action.arguments,
                reason: action.reason
            )
        }

        return ActionPlan(
            userQuery: query,
            summary: plan.summary,
            steps: steps,
            requiresConfirmation: plan.requiresConfirmation
        )
    }
}

// MARK: - Errors

enum ClaudePlannerError: Error, LocalizedError {
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let body):
            return "Claude API error \(code): \(body)"
        }
    }
}
