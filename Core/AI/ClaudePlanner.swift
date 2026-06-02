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
    let explanation: String?
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

    func createPlan(
        for query: String,
        candidates: [SearchResultItem],
        attachedFileContext: String?,
        history: [ConversationTurn]
    ) async throws -> ActionPlan {
        let prompt = buildPrompt(
            query: query,
            candidates: candidates,
            attachedFileContext: attachedFileContext
        )
        let json = try await callClaude(prompt: prompt, history: history)
        return try parsePlan(json: json, query: query)
    }

    // MARK: - Prompt

    private func buildPrompt(
        query: String,
        candidates: [SearchResultItem],
        attachedFileContext: String?
    ) -> String {
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
        mail_send_tool           | args: to, subject, body, attachmentPath (optional) [confirmationRequired]
        pdf_create_tool          | args: content, filename, savePath (optional — defaults to ~/Desktop) [confirmationRequired]
        file_attach_tool         | args: path, destination
        file_read_tool           | args: path (string)
        resume_find_tool         | args: (none)
        youtube_search_tool      | args: query (string), count (string, optional, default "3")
        """

        let attachedSection = attachedFileContext.map { "\n\($0)\n" } ?? ""
        let hasAttachedFiles = attachedFileContext != nil && !(attachedFileContext?.isEmpty ?? true)

        return """
        You are Oopla, an AI command bar for macOS. Your job is to convert a user's natural language command into a structured action plan.

        Note: a screenshot of the user's current screen may be attached to some requests as an image. \
        When present, use what you see on screen to fill in arguments (e.g. names, subjects, content).
        \(attachedSection)

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
        - mail_send_tool composes an email using the system mailto: scheme; confirmation always required.
        - pdf_create_tool creates a professional PDF from markdown/plain text; savePath is a directory (default ~/Desktop).
        - file_attach_tool copies a file to a destination folder for sharing or email attachment.
        - file_read_tool extracts text from .txt, .md, .pdf, or .docx files at the given path.
        - resume_find_tool locates the user's resume files on their Mac (newest first). \
        Skip this if the user already attached their resume as context below.
        - youtube_search_tool opens YouTube search results in the browser for a topic (does not scrape individual URLs).

        Screen study / explain — if the user asks to explain what's on screen, study help, or understand content \
        (and a screenshot may be attached):
        1. Write a clear, concise explanation in the "explanation" JSON field (2-4 short paragraphs, plain language, like a good tutor).
        2. Use an empty steps array if no tools are needed, or add youtube_search_tool if they want videos/resources.
        3. The explanation is shown as text in the UI; tool steps are executed separately.

        Distinguish between INFORMATIONAL questions and ACTION requests:
        INFORMATIONAL (answer in "explanation", avoid tool execution unless truly needed):
        - "where is his LinkedIn?", "what is X?", "who is this person?", "find me the link to...", "what's their email?"
        - For these, provide the answer directly in explanation.
        - If you genuinely need lookup to answer, you may use web_search_tool, but still summarize findings in explanation.
        - If a URL is visible/inferable from screen/context, include the full URL directly in explanation.

        ACTION (execute tools):
        - "open his LinkedIn", "go to that page", "take me to...", "launch...", "create...", "send..."
        - Use browser_open_url_tool, app_launcher_tool, etc.

        Difference rule:
        - "where/what/who/find the link" => tell me (explanation)
        - "open/go/take me/launch" => do it (tool step)

        Resume tailoring — if the user asks to tailor, adapt, or customize their resume for a job:
        \(hasAttachedFiles
            ? "- The user dropped their resume file(s) — use ONLY that attached content. Do NOT use resume_find_tool or file_read_tool for the resume."
            : "- Use resume_find_tool then file_read_tool to load their resume if not attached.")
        - Use job posting details from the screen (when provided via vision) or the user's command.
        - Write a tailored resume using ONLY real experience from their actual resume — never fabricate jobs, skills, or qualifications.
        - Put the full tailored resume markdown in pdf_create_tool's content argument.
        - Name the file Resume_[CompanyName].pdf and set requiresConfirmation to true.

        Local search candidates already found:
        \(candidateList.isEmpty ? "(none)" : candidateList)

        User command: "\(query)"

        Rules:
        - Use attached file content when the user dropped files — it is already provided above.
        - Use the local candidates when they are relevant (e.g. if user says "open my resume" and a resume file is in candidates, use file_open_tool with its path).
        - For multi-step commands (e.g. "open chrome and go to youtube"), produce multiple steps in order.
        - Set requiresConfirmation to true if any step creates, moves, deletes, or modifies files/folders.
        - NEVER invent resume content — only use facts from the user's real resume.
        - Keep summary short (one sentence) but include job context for resume flows.
        - Only use tools from the list above.
        - All argument values must be strings.

        Respond ONLY with a valid JSON object in this exact format (no markdown fences):
        {
          "summary": "short description of what you will do",
          "explanation": "detailed explanation for the user, or null if not an explain/study request",
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

    private func callClaude(prompt: String, history: [ConversationTurn]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: Any]] = history.suffix(10).map { turn in
            [
                "role": turn.role == "assistant" ? "assistant" : "user",
                "content": turn.content,
            ]
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": messages
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
            requiresConfirmation: plan.requiresConfirmation,
            explanation: plan.explanation
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
