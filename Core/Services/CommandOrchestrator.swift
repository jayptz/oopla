import Foundation
import OSLog

@MainActor
final class CommandOrchestrator: ObservableObject {
    @Published private(set) var searchResults: [SearchResultItem] = []
    @Published private(set) var executionState = CommandExecutionState()
    @Published private(set) var pendingConfirmation: ActionPlan?
    @Published private(set) var latestError: String?

    private let searchService: SearchProviding
    private let planner: PlannerProviding
    private let visionPlanner: PlannerProviding?
    private let registry: ToolRegistry
    private let safetyEvaluator: SafetyEvaluator
    private let logger = Logger(subsystem: "com.oopla.app", category: "orchestrator")

    init(
        searchService: SearchProviding,
        planner: PlannerProviding,
        visionPlanner: PlannerProviding? = nil,
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

    func planAndRun(query: String) async {
        latestError = nil

        do {
            let plan: ActionPlan

            if shouldEscalateToClaude(query: query, candidates: searchResults) {
                if requiresVision(query: query), let vp = visionPlanner {
                    executionState.statusLine = "Analyzing screen..."
                    logger.log("Vision mode — query: \"\(query)\"")
                    plan = try await vp.createPlan(for: query, candidates: searchResults)
                } else {
                    executionState.statusLine = "AI planning..."
                    logger.log("Escalating to Claude — query: \"\(query)\"")
                    plan = try await planner.createPlan(for: query, candidates: searchResults)
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
            executionState.steps = plan.steps.map { ExecutionStepState(id: $0.id, toolCall: $0, state: .pending) }
            executionState.statusLine = "Planned: \(plan.summary)"

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

    // MARK: - Vision gate

    /// Returns `true` when the query implies the user wants Claude to look at
    /// the current screen contents before planning.
    private func requiresVision(query: String) -> Bool {
        let q = query.lowercased()
        let triggers = [
            "screen", "look at", "read this", "what's on",
            "current page", "this email", "this job", "see my screen",
            "what i'm looking at", "on my screen", "from the screen"
        ]
        return triggers.contains { q.contains($0) }
    }

    // MARK: - Confidence gate

    /// Returns `true` when the query should be sent to Claude, `false` when
    /// a fast local plan can be built without an API call.
    private func shouldEscalateToClaude(query: String, candidates: [SearchResultItem]) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

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

        // App candidate: accept if the normalized term closely matches the title.
        if top.kind == .app {
            let title = top.title.lowercased()
            let isMatch = title == normalized
                || title.hasPrefix(normalized)
                || normalized.hasPrefix(title)
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
            // Chain context: if a downstream step needs a path, use the output
            // of the previous file_search_tool step automatically.
            if args["path"]?.isEmpty ?? true, let bestPath = runtimeContext["bestPath"] {
                args["path"] = bestPath
            }

            do {
                let result = try await tool.execute(arguments: args)
                if result.success {
                    result.payload.forEach { runtimeContext[$0.key] = $0.value }
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
}
