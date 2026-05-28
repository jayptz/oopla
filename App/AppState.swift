import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isCommandBarVisible: Bool = false
}
