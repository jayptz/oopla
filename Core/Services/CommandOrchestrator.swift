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
    private let registry: ToolRegistry
    private let safetyEvaluator: SafetyEvaluator
    private let logger = Logger(subsystem: "com.oopla.app", category: "orchestrator")

    init(searchService: SearchProviding, planner: PlannerProviding, registry: ToolRegistry) {
        self.searchService = searchService
        self.planner = planner
        self.registry = registry
        self.safetyEvaluator = SafetyEvaluator(registry: registry)
    }

    func updateSearch(for query: String) async {
        searchResults = await searchService.search(query: query)
    }

    func planAndRun(query: String) async {
        latestError = nil
        do {
            let plan = try await planner.createPlan(for: query, candidates: searchResults)
            let safety = safetyEvaluator.evaluate(plan: plan)
            executionState.currentPlan = plan
            executionState.steps = plan.steps.map { ExecutionStepState(id: $0.id, toolCall: $0, state: .pending) }
            executionState.statusLine = "Planned: \(plan.summary)"
            logger.log("Plan created with \(plan.steps.count) step(s), safety=\(String(describing: safety.level.rawValue))")

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
            // Allow chained calls: if a path is missing, try prior step output.
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
