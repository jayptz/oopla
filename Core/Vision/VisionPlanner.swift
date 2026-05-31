import AppKit
import Foundation

// MARK: - VisionPlanner

/// A drop-in replacement for ClaudePlanner that embeds a screenshot of the
/// user's screen alongside the text prompt, giving Claude visual context.
///
/// The Claude API vision format uses a `content` array instead of a plain
/// string, where the first element is the base64-encoded JPEG image and the
/// second is the text prompt. Everything else (tool schema, plan parsing,
/// safety) is identical to ClaudePlanner.
final class VisionPlanner: PlannerProviding {

    private let apiKey: String
    private let model: String
    private let captureService: ScreenCaptureService
    private let session = URLSession.shared
    private let fallback: ClaudePlanner

    /// Max compressed JPEG size sent to the API (1 MB).
    private static let maxImageBytes = 1_048_576

    init(
        apiKey: String,
        model: String = "claude-sonnet-4-20250514",
        captureService: ScreenCaptureService
    ) {
        self.apiKey          = apiKey
        self.model           = model
        self.captureService  = captureService
        self.fallback        = ClaudePlanner(apiKey: apiKey, model: model)
    }

    // MARK: - PlannerProviding

    func createPlan(for query: String, candidates: [SearchResultItem]) async throws -> ActionPlan {
        // Attempt screen capture. On failure, fall back to text-only planning
        // so the user still gets an answer even without Screen Recording permission.
        let base64: String?
        do {
            let image = try await captureService.captureScreen()
            base64 = encodeImage(image)
        } catch {
            base64 = nil
        }

        let prompt = buildPrompt(query: query, candidates: candidates)

        if let b64 = base64 {
            let json = try await callClaudeWithVision(prompt: prompt, base64JPEG: b64)
            return try parsePlan(json: json, query: query)
        } else {
            // No screenshot available — delegate to the text-only planner.
            return try await fallback.createPlan(for: query, candidates: candidates)
        }
    }

    // MARK: - Image encoding

    /// Resizes and JPEG-compresses the image until it fits within `maxImageBytes`.
    private func encodeImage(_ image: NSImage, maxBytes: Int = maxImageBytes) -> String? {
        var size = image.size
        var compressionFactor: CGFloat = 0.85

        while true {
            guard let cgImage = renderCGImage(image, size: size) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: compressionFactor]
            ) else { return nil }

            if data.count <= maxBytes { return data.base64EncodedString() }

            // Reduce resolution by 25 % each pass; drop quality as a last resort.
            if size.width > 600 {
                size = NSSize(width: size.width * 0.75, height: size.height * 0.75)
            } else if compressionFactor > 0.3 {
                compressionFactor -= 0.2
            } else {
                // Return whatever we have even if it slightly exceeds the limit.
                return data.base64EncodedString()
            }
        }
    }

    private func renderCGImage(_ image: NSImage, size: NSSize) -> CGImage? {
        let dest = NSImage(size: size)
        dest.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        dest.unlockFocus()
        return dest.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - API call (vision)

    private func callClaudeWithVision(prompt: String, base64JPEG: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",   forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,               forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",         forHTTPHeaderField: "anthropic-version")

        // Multi-modal content: image first, then text.
        let imageBlock: [String: Any] = [
            "type": "image",
            "source": [
                "type":       "base64",
                "media_type": "image/jpeg",
                "data":        base64JPEG
            ]
        ]
        let textBlock: [String: Any] = [
            "type": "text",
            "text": prompt
        ]

        let body: [String: Any] = [
            "model":      model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": [imageBlock, textBlock]]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PlannerError.invalidPlan
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ClaudePlannerError.apiError(statusCode: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw PlannerError.invalidPlan
        }
        return text
    }

    // MARK: - Prompt (identical to ClaudePlanner, with a vision note prepended)

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
        mail_send_tool           | args: to, subject, body, attachmentPath (optional) [confirmationRequired]
        pdf_create_tool          | args: content, filename, savePath
        file_attach_tool         | args: path, destination
        """

        return """
        You are Oopla, an AI command bar for macOS. Your job is to convert a user's natural language command into a structured action plan.

        IMPORTANT: A screenshot of the user's current screen is attached to this message as an image. \
        Use what you see on screen to inform your plan — for example, if the user says "this email" or \
        "this job posting", identify the relevant content from the screenshot and incorporate it into your tool arguments.

        Available tools:
        \(tools)

        Tool notes:
        - app_launcher_tool can launch ANY application installed on the user's Mac. \
        Pass the app's common display name exactly as the user would say it. The tool resolves name variants automatically.
        - browser_open_url_tool opens a URL in the default browser. Use it for web destinations rather than launching a browser separately.
        - mail_send_tool composes an email using the system mailto: scheme; use it when the user wants to send or draft an email.
        - pdf_create_tool creates a PDF from plain-text or markdown content; savePath should be a directory path.
        - file_attach_tool copies a file to a destination for email attachments or sharing.

        Local search candidates already found:
        \(candidateList.isEmpty ? "(none)" : candidateList)

        User command: "\(query)"

        Rules:
        - Reference screen content when the user says "this", "current", "what's on screen", etc.
        - Use local candidates when relevant.
        - For multi-step commands produce multiple steps in order.
        - Set requiresConfirmation to true if any step creates, moves, or modifies files/sends email.
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

    // MARK: - Plan parsing (mirrors ClaudePlanner exactly)

    private func parsePlan(json: String, query: String) throws -> ActionPlan {
        let cleaned = json
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { throw PlannerError.invalidPlan }

        let plan = try JSONDecoder().decode(ClaudePlan.self, from: data)
        let steps = plan.steps.map { action in
            ToolCall(toolName: action.toolName, arguments: action.arguments, reason: action.reason)
        }
        return ActionPlan(
            userQuery: query,
            summary: plan.summary,
            steps: steps,
            requiresConfirmation: plan.requiresConfirmation
        )
    }
}

// MARK: - Shared decodable types (mirrors ClaudePlanner; declared fileprivate
//         here to avoid duplicate-declaration errors since ClaudePlanner uses
//         private types with the same names in the same module).

// These are accessed via the ClaudePlanner module-internal symbols.
// Re-declared as private here so VisionPlanner is fully self-contained.

private struct ClaudeResponse: Decodable {
    let content: [ClaudeContentBlock]
}
private struct ClaudeContentBlock: Decodable {
    let type: String; let text: String?
}
private struct PlannedAction: Decodable {
    let toolName: String; let arguments: [String: String]; let reason: String
}
private struct ClaudePlan: Decodable {
    let summary: String; let requiresConfirmation: Bool; let steps: [PlannedAction]
}
