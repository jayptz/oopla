import AppKit

/// Manages the persistent menu bar icon that keeps Oopla alive in the
/// background and gives users a guaranteed click-to-open fallback.
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    /// Called whenever the user clicks the icon or chooses "Open Oopla".
    var onToggle: (() -> Void)?
    /// Called when the user chooses Quit from the menu.
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        configureButton()
        configureMenu()
    }

    // MARK: - Private

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Oopla")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(iconClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Oopla", action: #selector(openOopla), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Oopla", action: #selector(quitOopla), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        // Show the menu on right-click; toggle the bar on left-click.
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.button?.performClick(nil)
        } else {
            onToggle?()
        }
    }

    @objc private func openOopla() {
        onToggle?()
    }

    @objc private func quitOopla() {
        onQuit?()
    }
}
