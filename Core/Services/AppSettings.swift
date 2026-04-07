import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var shortcutDisplay: String = "Cmd + Shift + Space"
    @Published var autoRunSafeActions: Bool = true
    @Published var showRecentCommands: Bool = true
    @Published var searchDesktop: Bool = true
    @Published var searchDocuments: Bool = true
    @Published var searchDownloads: Bool = true
    @Published var aiProviderName: String = "Mock Planner"
}
