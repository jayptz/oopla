import AppKit
import Foundation

@MainActor
final class HotkeyService: ObservableObject {
    @Published private(set) var isRegistered: Bool = false
    var onTrigger: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // MVP uses Cmd+Shift+Space to avoid overriding Spotlight by default.
    // A production build can swap this with Carbon RegisterEventHotKey.
    func registerDefaultHotkey() {
        unregister()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }
        isRegistered = true
    }

    func unregister() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        isRegistered = false
    }

    private func handle(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmdShift = flags.contains(.command) && flags.contains(.shift)
        let isSpace = event.keyCode == 49
        if isCmdShift && isSpace {
            onTrigger?()
        }
    }
}
