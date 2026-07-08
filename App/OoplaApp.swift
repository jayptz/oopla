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
        let registry    = ToolRegistry.makeDefault()
        let apiKey      = EnvLoader.get("ANTHROPIC_API_KEY") ?? ""
        let capture     = ScreenCaptureService()
        _orchestrator = StateObject(
            wrappedValue: CommandOrchestrator(
                searchService: LocalSearchIndex(),
                planner:       ClaudePlanner(apiKey: apiKey),
                visionPlanner: VisionPlanner(apiKey: apiKey, captureService: capture),
                registry:      registry
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
    @State private var resignObserver: NSObjectProtocol?

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
            installWindowObservers()
        }
        .onDisappear {
            removeWindowObservers()
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
        applyBorderlessStyle(to: w)
        w.orderOut(nil)
    }

    private func showWindow() {
        guard let w = mainWindow else { return }
        // Re-apply every time because WindowGroup may restore chrome.
        applyBorderlessStyle(to: w)
        guard let screen = screenContainingMouse() ?? w.screen ?? NSScreen.main else { return }
        let sz = w.frame
        let x = screen.visibleFrame.midX - sz.width / 2
        // Centered horizontally, about 20% down from top (Spotlight-like).
        let y = screen.visibleFrame.maxY - (screen.visibleFrame.height * 0.2) - (sz.height / 2)
        w.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKey()
        w.makeKeyAndOrderFront(nil)
    }

    private func hideWindow() {
        mainWindow?.orderOut(nil)
    }

    private func applyBorderlessStyle(to w: NSWindow) {
        w.styleMask = [.borderless, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.isMovable = true
        w.isReleasedWhenClosed = false
    }

    private func installWindowObservers() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Spotlight-like click-away dismissal.
            Task { @MainActor in
                appState.isCommandBarVisible = false
            }
        }
    }

    private func removeWindowObservers() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
