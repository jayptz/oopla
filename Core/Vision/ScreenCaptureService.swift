import AppKit
import ScreenCaptureKit

// MARK: - ScreenCaptureService

/// Captures a single full-screen frame from the main display using
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

    /// Captures the primary display as a single frame.
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

        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Filter: capture the entire display, excluding nothing.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        // Native resolution; for Retina this is 2× the point size.
        config.width  = display.width
        config.height = display.height
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
}
