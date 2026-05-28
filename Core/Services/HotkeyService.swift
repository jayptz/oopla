import AppKit
import Foundation

@MainActor
final class HotkeyService: ObservableObject {
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false

    var onTrigger: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    func registerDefaultHotkey() {
        checkAccessibility()
        unregister()

        // Local monitor catches Option+Space while Oopla itself is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
            // Return nil to consume the event so it doesn't type a space into
            // the text field when the hotkey fires while the bar is already up.
            if self?.isHotkey(event) == true { return nil }
            return event
        }

        // Global monitor fires while any OTHER app is frontmost.
        // Requires Input Monitoring permission (System Settings → Privacy & Security
        // → Input Monitoring). Without it this callback is silently never called.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }

        isRegistered = true
    }

    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isRegistered = false
    }

    func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    private func handle(event: NSEvent) {
        if isHotkey(event) {
            onTrigger?()
        }
    }

    private func isHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+Shift+Space — no macOS system conflicts.
        return flags == [.command, .shift] && event.keyCode == 49
    }
}
