import Foundation
import OSLog

@MainActor
final class CommandOrchestrator: ObservableObject {
    @Published private(set) var searchResults: [SearchResultItem] = []
    @Published private(set) var executionState = CommandExecutionState()
    @Published private(set) var pendingConfirmation: ActionPlan?
    @Published private(set) var latestError: String?
    @Published private(set) var conversation: [ConversationTurn] = []

    private let searchService: SearchProviding
    private let planner: PlannerProviding
    private let visionPlanner: VisionPlanner?
    private let registry: ToolRegistry
    private let safetyEvaluator: SafetyEvaluator
    private let logger = Logger(subsystem: "com.oopla.app", category: "orchestrator")
    private var activeConversationScreenBase64: String?

    init(
        searchService: SearchProviding,
        planner: PlannerProviding,
        visionPlanner: VisionPlanner? = nil,
        registry: ToolRegistry
    ) {
        self.searchService  = searchService
        self.planner        = planner
        self.visionPlanner  = visionPlanner
        self.registry       = registry
        self.safetyEvaluator = SafetyEvaluator(registry: registry)
    }

    func updateSearch(for query: String) async {
        searchResults = await searchService.search(query: query)
    }

    func planAndRun(query: String, attachedFiles: [URL] = []) async {
        await runTurn(query: query, attachedFiles: attachedFiles)
    }

    func continueConversation(query: String, attachedFiles: [URL] = []) async {
        await runTurn(query: query, attachedFiles: attachedFiles)
    }

    func clearConversation() {
        conversation.removeAll()
        activeConversationScreenBase64 = nil
        executionState.currentPlan = nil
        executionState.steps = []
        executionState.explanation = nil
        executionState.statusLine = "Ready"
        latestError = nil
    }

    private func runTurn(query: String, attachedFiles: [URL]) async {
        latestError = nil
        executionState.explanation = nil

        do {
            let plan: ActionPlan
            let attachedContext = await buildAttachedFileContext(from: attachedFiles)
            let history = Array(conversation.suffix(10))

            if shouldEscalateToClaude(query: query, candidates: searchResults) {
                if requiresVision(query: query), let vp = visionPlanner {
                    executionState.statusLine = "Analyzing screen..."
                    logger.log("Vision mode — query: \"\(query)\"")
                    let shouldRecapture = shouldRefreshScreenContext(query: query) || activeConversationScreenBase64 == nil
                    let (visionPlan, usedBase64) = try await vp.createPlanWithVisionContext(
                        for: query,
                        candidates: searchResults,
                        attachedFileContext: attachedContext,
                        history: history,
                        preferredScreenBase64: activeConversationScreenBase64,
                        shouldRecapture: shouldRecapture
                    )
                    activeConversationScreenBase64 = usedBase64 ?? activeConversationScreenBase64
                    plan = visionPlan
                } else {
                    executionState.statusLine = "AI planning..."
                    logger.log("Escalating to Claude — query: \"\(query)\"")
                    plan = try await planner.createPlan(
                        for: query,
                        candidates: searchResults,
                        attachedFileContext: attachedContext,
                        history: history
                    )
                }
                logger.log("Claude returned plan with \(plan.steps.count) step(s)")
            } else {
                // Safe to unwrap: shouldEscalateToClaude returns false only
                // when a strong local candidate exists.
                let top = searchResults.first!
                executionState.statusLine = "Local match — \(top.title)"
                logger.log("Local match: \"\(top.title)\" (score \(top.score)) for query: \"\(query)\"")
                plan = buildLocalPlan(query: query, candidate: top)
            }

            let safety = safetyEvaluator.evaluate(plan: plan)
            executionState.currentPlan = plan
            executionState.explanation = plan.explanation
            executionState.steps = plan.steps.map { ExecutionStepState(id: $0.id, toolCall: $0, state: .pending) }
            executionState.statusLine = plan.explanation != nil
                ? "Explanation ready"
                : "Planned: \(plan.summary)"

            appendConversationTurn(role: "user", content: query)
            appendConversationTurn(role: "assistant", content: plan.explanation ?? plan.summary)

            switch safety.level {
            case .safe:
                await execute(plan: plan)
            case .confirmationRequired, .destructive:
                pendingConfirmation = plan
                executionState.statusLine = "Confirmation required: \(safety.reason)"
            }
        } catch {
            latestError = "Could not create plan: \(error.localizedDescription)"
            executionState.statusLine = "Failed to plan command."
            appendConversationTurn(role: "user", content: query)
            appendConversationTurn(role: "assistant", content: "I ran into an issue: \(error.localizedDescription)")
        }
    }

    func approvePendingPlan() async {
        guard let plan = pendingConfirmation else { return }
        pendingConfirmation = nil
        await execute(plan: plan)
    }

    func cancelPendingPlan() {
        pendingConfirmation = nil
        executionState.statusLine = "Cancelled."
    }

    // MARK: - Attached files

    /// Reads dropped files and formats them for the planner prompt.
    private func buildAttachedFileContext(from urls: [URL]) async -> String? {
        guard !urls.isEmpty else { return nil }

        var sections: [String] = []
        let reader = FileReadTool()

        for url in urls {
            let result = try? await reader.execute(arguments: ["path": url.path])
            let content = result?.payload["content"] ?? "(could not read file)"
            sections.append("""
            --- \(url.lastPathComponent) ---
            \(content)
            """)
        }

        return """
        The user has attached the following file(s) as context:
        \(sections.joined(separator: "\n\n"))
        """
    }

    private func appendConversationTurn(role: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.append(ConversationTurn(role: role, content: trimmed))
        if conversation.count > 20 {
            conversation = Array(conversation.suffix(20))
        }
    }

    private func shouldRefreshScreenContext(query: String) -> Bool {
        let q = query.lowercased()
        return q.contains("look again")
            || q.contains("again")
            || q.contains("now")
            || q.contains("current screen")
            || q.contains("what's on my screen now")
    }

    // MARK: - Vision gate

    /// Returns `true` when the query implies the user wants Claude to look at
    /// the current screen contents before planning.
    private func requiresVision(query: String) -> Bool {
        let q = query.lowercased()
        let triggers = [
            "screen", "look at", "read this", "what's on",
            "current page", "this email", "this job", "see my screen",
            "what i'm looking at", "on my screen", "from the screen",
            "tailor my resume", "tailor resume", "customize my resume",
            "adapt my resume", "resume to this job", "job application",
            "explain what's on", "explain what is on", "explain this",
            "explain my screen", "what's on my screen", "study help",
            "help me understand", "youtube video"
        ]
        if triggers.contains(where: { q.contains($0) }) { return true }

        let mentionsResume = q.contains("resume") || q.contains(" cv")
        let mentionsTailor = ["tailor", "customize", "customise", "adapt", "adjust"]
            .contains { q.contains($0) }
        return mentionsResume && mentionsTailor
    }

    // MARK: - Confidence gate

    /// Returns `true` when the query should be sent to Claude, `false` when
    /// a fast local plan can be built without an API call.
    private func shouldEscalateToClaude(query: String, candidates: [SearchResultItem]) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Vision queries always go to Claude — never short-circuit locally.
        if requiresVision(query: query) {
            logger.log("Escalation reason: vision query")
            return true
        }

        // ── Tier 2 triggers ────────────────────────────────────────────────

        // Multi-step intent: "open X and go to Y", "do this then that".
        let multiStepMarkers = [" and ", " then ", " after "]
        if multiStepMarkers.contains(where: { q.contains($0) }) {
            logger.log("Escalation reason: multi-step marker in \"\(q)\"")
            return true
        }

        // Mutating / creative intent.
        let mutatingWords = [
            "create", "make", "new folder", "move", "rename", "delete",
            "remove", "copy", "zip", "email", "send", "draft",
            "calendar", "event", "note", "reminder", "schedule"
        ]
        if mutatingWords.contains(where: { q.contains($0) }) {
            logger.log("Escalation reason: mutating keyword in \"\(q)\"")
            return true
        }

        // Web / browser intent.
        let webWords = [
            "search", "google", "browser", "http", "www.",
            ".com", ".org", ".io", "youtube", "gmail", "github"
        ]
        if webWords.contains(where: { q.contains($0) }) {
            logger.log("Escalation reason: web keyword in \"\(q)\"")
            return true
        }

        // ── Tier 1 check ───────────────────────────────────────────────────

        guard let top = candidates.first else {
            logger.log("Escalation reason: no local candidates")
            return true
        }

        // Strip launcher prefixes so "open spotify" reduces to "spotify"
        // before we compare it to the candidate title.
        let launcherPrefixes = ["open ", "launch ", "start ", "show ", "run "]
        var normalized = q
        for prefix in launcherPrefixes {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
                break
            }
        }

        // App candidate: short-circuit only when the user typed enough of the
        // app name to be unambiguous (≥ 3 chars) AND the title is a close match.
        // This prevents single-keystrokes like "r" from instantly launching
        // Raycast instead of going to Claude, and stops long natural-language
        // queries from accidentally matching short app names.
        if top.kind == .app {
            guard normalized.count >= 3 else {
                logger.log("Escalation reason: normalized query '\(normalized)' too short for local match")
                return true
            }
            let title = top.title.lowercased()
            // Accept only if the app name starts with the query, equals it, or
            // is fully contained in it (e.g. "spotify" → title "Spotify").
            // We do NOT accept normalized.hasPrefix(title) because that would
            // allow a short app name like "screen" to match "what is my screen
            // showing", bypassing Claude.
            let isMatch = title == normalized
                || title.hasPrefix(normalized)
                || title.contains(normalized)
            if isMatch { return false }
            logger.log("Escalation reason: app candidate '\(top.title)' didn't match normalized '\(normalized)'")
            return true
        }

        // File / folder candidate: require strong score from local search.
        if top.kind == .file || top.kind == .folder {
            if top.score >= 0.8 { return false }
            logger.log("Escalation reason: file score \(top.score) below threshold")
            return true
        }

        // Any other result kind (aiAction, web, action) → always escalate.
        return true
    }

    // MARK: - Local plan builder

    /// Constructs a single-step ActionPlan from a high-confidence local
    /// candidate without calling the planner.
    private func buildLocalPlan(query: String, candidate: SearchResultItem) -> ActionPlan {
        let step: ToolCall

        switch candidate.kind {
        case .app:
            step = ToolCall(
                toolName: "app_launcher_tool",
                arguments: ["appName": candidate.title],
                reason: "High-confidence local match for '\(candidate.title)'"
            )
        case .file, .folder:
            step = ToolCall(
                toolName: "file_open_tool",
                arguments: ["path": candidate.path ?? ""],
                reason: "High-confidence local match for '\(candidate.title)'"
            )
        default:
            // Shouldn't reach here given the gate logic, but handle gracefully.
            step = ToolCall(
                toolName: "file_open_tool",
                arguments: ["path": candidate.path ?? ""],
                reason: "Local fallback"
            )
        }

        return ActionPlan(
            userQuery: query,
            summary: "Open \(candidate.title).",
            steps: [step],
            requiresConfirmation: false
        )
    }

    // MARK: - Execution engine

    private func execute(plan: ActionPlan) async {
        executionState.statusLine = "Executing \(plan.steps.count) step(s)..."
        var runtimeContext: [String: String] = [:]

        // Job posting / intent from the plan summary (vision flows).
        if !plan.summary.isEmpty {
            runtimeContext["jobContext"] = plan.summary
        }

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").path

        for i in executionState.steps.indices {
            var step = executionState.steps[i]
            step.state = .running
            executionState.steps[i] = step

            guard let tool = registry.tool(named: step.toolCall.toolName) else {
                step.state = .failed("Tool not registered.")
                executionState.steps[i] = step
                executionState.statusLine = "Execution failed."
                return
            }

            var args = step.toolCall.arguments
            args = injectChainedArguments(
                toolName: step.toolCall.toolName,
                args: args,
                context: runtimeContext,
                desktopPath: desktop
            )

            do {
                let result = try await tool.execute(arguments: args)
                if result.success {
                    result.payload.forEach { runtimeContext[$0.key] = $0.value }
                    // Preserve tailored PDF body if planner passed it in the step args.
                    if step.toolCall.toolName == "pdf_create_tool",
                       let content = args["content"], !content.isEmpty {
                        runtimeContext["tailoredContent"] = content
                    }
                    step.state = .succeeded(result.message)
                    executionState.steps[i] = step
                } else {
                    step.state = .failed(result.message)
                    executionState.steps[i] = step
                    executionState.statusLine = "Execution stopped."
                    return
                }
            } catch {
                step.state = .failed(error.localizedDescription)
                executionState.steps[i] = step
                executionState.statusLine = "Execution failed."
                return
            }
        }
        executionState.statusLine = "Done."
    }

    /// Fills missing tool arguments from prior step payloads (resume paths, file content, etc.).
    private func injectChainedArguments(
        toolName: String,
        args: [String: String],
        context: [String: String],
        desktopPath: String
    ) -> [String: String] {
        var args = args

        // Path: resume_find → file_read / file_open
        if args["path"]?.isEmpty ?? true {
            if let p = context["resume1Path"] { args["path"] = p }
            else if let p = context["bestPath"] { args["path"] = p }
        }

        switch toolName {
        case "file_read_tool":
            if args["path"]?.isEmpty ?? true, let p = context["resume1Path"] {
                args["path"] = p
            }

        case "pdf_create_tool":
            if args["savePath"]?.isEmpty ?? true {
                args["savePath"] = desktopPath
            }
            // Use planner-provided tailored body, or fall back to step content in context.
            let placeholder = args["content"] ?? ""
            if placeholder.isEmpty || placeholder == "__RUNTIME__" {
                if let tailored = context["tailoredContent"], !tailored.isEmpty {
                    args["content"] = tailored
                } else if let raw = context["content"], !raw.isEmpty {
                    args["content"] = raw
                }
            }

        default:
            break
        }

        return args
    }
}
