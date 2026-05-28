import AppKit
import SwiftUI

@main
struct OoplaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()
    @StateObject private var hotkeyService = HotkeyService()
    @StateObject private var orchestrator: CommandOrchestrator

    // Kept as a plain property (not StateObject) because StatusBarController
    // is an NSObject and its lifecycle is app-scoped, not view-scoped.
    private let statusBar = StatusBarController()

    init() {
        let registry = ToolRegistry.makeDefault()
        _orchestrator = StateObject(
            wrappedValue: CommandOrchestrator(
                searchService: LocalSearchIndex(),
                planner: ClaudePlanner(apiKey: EnvLoader.get("ANTHROPIC_API_KEY") ?? ""),
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
                .onAppear {
                    // No Dock icon — this is a menu bar + hotkey utility.
                    NSApp.setActivationPolicy(.accessory)

                    // Shared toggle logic used by both the hotkey and the
                    // menu bar icon so behaviour is always consistent.
                    let toggle = {
                        appState.isCommandBarVisible.toggle()
                        if appState.isCommandBarVisible {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }

                    statusBar.onToggle = toggle
                    statusBar.onQuit   = { NSApp.terminate(nil) }

                    hotkeyService.onTrigger = toggle
                    hotkeyService.registerDefaultHotkey()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 480, height: 360)
        }
    }
}

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            if appState.isCommandBarVisible {
                CommandBarView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                // Invisible placeholder keeps the window at a stable size
                // while hidden so positioning is accurate on next show.
                Color.clear.frame(width: 560, height: 60)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: appState.isCommandBarVisible)
        .background(Color.clear)
        .onAppear {
            configureAndHideWindow()
        }
        .onChange(of: appState.isCommandBarVisible) { visible in
            if visible {
                // Defer one run-loop tick so SwiftUI finishes layout before
                // we read the window's content size for positioning.
                DispatchQueue.main.async { showWindow() }
            } else {
                hideWindow()
            }
        }
    }

    // MARK: Window helpers

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            ?? NSApp.windows.first
    }

    private func configureAndHideWindow() {
        guard let w = mainWindow else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
        w.styleMask = [.borderless, .fullSizeContentView]
        w.level = .floating
        w.collectionBehavior = [.transient, .canJoinAllSpaces, .ignoresCycle]
        w.hasShadow = true
        w.isMovable = false
        w.isReleasedWhenClosed = false
        w.orderOut(nil)
    }

    private func showWindow() {
        guard let w = mainWindow else { return }
        guard let screen = w.screen ?? NSScreen.main else { return }
        let sz = w.frame
        let x  = screen.visibleFrame.midX - sz.width / 2
        let y  = screen.visibleFrame.maxY  - sz.height - screen.visibleFrame.height / 3
        w.setFrameOrigin(NSPoint(x: x, y: y))
        w.makeKeyAndOrderFront(nil)
    }

    private func hideWindow() {
        mainWindow?.orderOut(nil)
    }
}
