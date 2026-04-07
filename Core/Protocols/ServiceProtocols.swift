import Foundation

protocol SearchProviding {
    func search(query: String) async -> [SearchResultItem]
}

protocol PlannerProviding {
    func createPlan(for query: String, candidates: [SearchResultItem]) async throws -> ActionPlan
}

protocol ToolProtocol {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: String] { get }
    var resultSchema: [String: String] { get }
    var safetyLevel: SafetyLevel { get }

    func execute(arguments: [String: String]) async throws -> ToolResult
}

protocol AIProvider {
    var providerName: String { get }
    func structuredPlan(prompt: String, schema: String) async throws -> String
}
