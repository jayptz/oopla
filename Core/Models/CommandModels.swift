import Foundation

enum ResultKind: String, Codable, Hashable {
    case app
    case file
    case folder
    case action
    case aiAction
    case web
}

struct SearchResultItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let kind: ResultKind
    let path: String?
    let score: Double
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        kind: ResultKind,
        path: String? = nil,
        score: Double,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.path = path
        self.score = score
        self.metadata = metadata
    }
}

enum SafetyLevel: String, Codable {
    case safe
    case confirmationRequired
    case destructive
}

struct ToolCall: Identifiable, Codable, Hashable {
    let id: UUID
    let toolName: String
    let arguments: [String: String]
    let reason: String

    init(id: UUID = UUID(), toolName: String, arguments: [String: String], reason: String) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.reason = reason
    }
}

struct ActionPlan: Identifiable, Codable, Hashable {
    let id: UUID
    let userQuery: String
    let summary: String
    let steps: [ToolCall]
    let requiresConfirmation: Bool

    init(
        id: UUID = UUID(),
        userQuery: String,
        summary: String,
        steps: [ToolCall],
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.userQuery = userQuery
        self.summary = summary
        self.steps = steps
        self.requiresConfirmation = requiresConfirmation
    }
}

struct ToolResult: Codable, Hashable {
    let toolName: String
    let success: Bool
    let message: String
    let payload: [String: String]
}

struct ExecutionStepState: Identifiable, Hashable {
    enum State: Hashable {
        case pending
        case running
        case succeeded(String)
        case failed(String)
    }

    let id: UUID
    let toolCall: ToolCall
    var state: State
}

struct CommandExecutionState: Hashable {
    var currentPlan: ActionPlan?
    var steps: [ExecutionStepState] = []
    var statusLine: String = "Ready"
}
