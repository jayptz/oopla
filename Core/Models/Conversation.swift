import Foundation

struct ConversationTurn: Identifiable, Codable, Hashable {
    let id: UUID
    let role: String   // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

