import Foundation

struct SafetyDecision {
    let level: SafetyLevel
    let reason: String
}

final class SafetyEvaluator {
    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    func evaluate(plan: ActionPlan) -> SafetyDecision {
        var strongest: SafetyLevel = plan.requiresConfirmation ? .confirmationRequired : .safe
        var reason = "All actions are safe."

        for step in plan.steps {
            guard let tool = registry.tool(named: step.toolName) else { continue }
            switch tool.safetyLevel {
            case .destructive:
                strongest = .destructive
                reason = "\(tool.name) is destructive."
                return SafetyDecision(level: strongest, reason: reason)
            case .confirmationRequired where strongest != .destructive:
                strongest = .confirmationRequired
                reason = "\(tool.name) requires confirmation."
            case .safe:
                break
            default:
                break
            }
        }
        return SafetyDecision(level: strongest, reason: reason)
    }
}
