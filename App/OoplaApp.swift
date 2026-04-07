import SwiftUI

@main
struct OoplaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()
    @StateObject private var hotkeyService = HotkeyService()
    @StateObject private var orchestrator: CommandOrchestrator

    init() {
        let registry = ToolRegistry.makeDefault()
        _orchestrator = StateObject(
            wrappedValue: CommandOrchestrator(
                searchService: LocalSearchIndex(),
                planner: MockPlanner(),
                registry: registry
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(hotkeyService)
                .environmentObject(orchestrator)
                .frame(minWidth: 760, idealWidth: 840, minHeight: 560, idealHeight: 620)
                .onAppear {
                    hotkeyService.onTrigger = {
                        appState.isCommandBarVisible.toggle()
                    }
                    hotkeyService.registerDefaultHotkey()
                }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 480, height: 360)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.9), .gray.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if appState.isCommandBarVisible {
                CommandBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: appState.isCommandBarVisible)
    }
}
