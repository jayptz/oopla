import AppKit
import ScreenCaptureKit

// MARK: - ScreenCaptureService

/// Captures a single full-screen frame from the active display using
/// ScreenCaptureKit's one-shot screenshot API (macOS 14+).
///
/// Permission note:
/// The app must be listed under System Preferences → Privacy & Security →
/// Screen Recording. On first use, SCShareableContent.current will throw
/// SCStreamError if the user hasn't granted access. Users can add Oopla
/// manually in the Screen Recording list, or re-run after granting access.
final class ScreenCaptureService {

    enum CaptureError: Error, LocalizedError {
        case noDisplayFound
        case permissionDenied(String)
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplayFound:
                return "No display is available for capture."
            case .permissionDenied(let msg):
                return "Screen recording permission denied. Enable Oopla in System Settings → Privacy & Security → Screen Recording. (\(msg))"
            case .captureFailed(let msg):
                return "Screen capture failed: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Captures the display the user is actively on (mouse cursor screen), not always the primary monitor.
    /// Throws `CaptureError` if permission is denied or capture fails.
    func captureScreen() async throws -> NSImage {
        // SCShareableContent.current is the permission gate.
        // If the user hasn't granted Screen Recording, this throws.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied(error.localizedDescription)
        }

        guard let display = displayForCapture(in: content) else {
            throw CaptureError.noDisplayFound
        }

        // Filter: capture the entire display, excluding nothing.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        // Request true native pixel resolution (retina-aware).
        // Prefer CoreGraphics pixel dimensions when available.
        let pixelWidth = Int(CGDisplayPixelsWide(display.displayID))
        let pixelHeight = Int(CGDisplayPixelsHigh(display.displayID))
        config.width = pixelWidth > 0 ? pixelWidth : display.width
        config.height = pixelHeight > 0 ? pixelHeight : display.height
        config.capturesAudio = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    // MARK: - Display selection

    /// Picks the monitor under the cursor, then Oopla's window screen, then the menu-bar screen.
    private func displayForCapture(in content: SCShareableContent) -> SCDisplay? {
        let displays = content.displays
        guard !displays.isEmpty else { return nil }

        if let screen = screenContainingMouse(),
           let match = displayMatching(screen: screen, in: displays) {
            return match
        }

        if let windowScreen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen,
           let match = displayMatching(screen: windowScreen, in: displays) {
            return match
        }

        if let main = NSScreen.main,
           let match = displayMatching(screen: main, in: displays) {
            return match
        }

        return displays.first
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func displayMatching(screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        guard
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        let displayID = CGDirectDisplayID(truncating: screenNumber)
        return displays.first { $0.displayID == displayID }
    }
}
