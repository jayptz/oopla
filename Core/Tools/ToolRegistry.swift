import AppKit
import Foundation
import PDFKit

final class ToolRegistry {
    private var tools: [String: ToolProtocol] = [:]

    init(tools: [ToolProtocol]) {
        tools.forEach { self.tools[$0.name] = $0 }
    }

    func tool(named name: String) -> ToolProtocol? {
        tools[name]
    }

    func allTools() -> [ToolProtocol] {
        tools.values.sorted { $0.name < $1.name }
    }

    static func makeDefault() -> ToolRegistry {
        ToolRegistry(
            tools: [
                AppLauncherTool(),
                FileSearchTool(),
                FileOpenTool(),
                FileMoveTool(),
                FileRenameTool(),
                FileZipTool(),
                BrowserOpenURLTool(),
                WebSearchTool(),
                ClipboardReadTool(),
                ClipboardWriteTool(),
                NoteCreateTool(),
                CalendarCreateTool(),
                EmailDraftTool(),
                FolderCreateTool(),
                FinderRevealTool(),
                SystemDNDTool(),
                MailSendTool(),
                PDFCreateTool(),
                FileAttachTool()
            ]
        )
    }
}

struct AppLauncherTool: ToolProtocol {
    let name = "app_launcher_tool"
    let description = """
        Launches any installed macOS application by its common display name. \
        Works with any app the user has installed. Pass the app's common name \
        as the user would say it (e.g. "Cursor", "Arc", "Spotify", "VS Code", \
        "Chrome"). The tool resolves common name variants automatically.
        """
    let inputSchema  = ["appName": "String — common display name of the app"]
    let resultSchema = ["launchedApp": "String"]
    let safetyLevel: SafetyLevel = .safe

    // Maps spoken/informal names → actual .app bundle names.
    // Only entries where the two differ are needed here.
    private static let aliases: [String: String] = [
        // Browsers
        "chrome":                  "Google Chrome",
        "google chrome":           "Google Chrome",
        "brave":                   "Brave Browser",
        // Developer tools
        "vs code":                 "Visual Studio Code",
        "vscode":                  "Visual Studio Code",
        "visual studio code":      "Visual Studio Code",
        "iterm":                   "iTerm",
        "iterm2":                  "iTerm",
        "intellij":                "IntelliJ IDEA",
        "sublime":                 "Sublime Text",
        // Communication / productivity
        "zoom":                    "zoom.us",
        "teams":                   "Microsoft Teams",
        "microsoft teams":         "Microsoft Teams",
        "google meet":             "Google Meet",
        // Password managers / utilities
        "1password":               "1Password 7 - Password Manager",
        "cleanmymac":              "CleanMyMac X",
    ]

    // Directories searched in priority order.
    private static let searchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let rawName = arguments["appName"], !rawName.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing appName.", payload: [:])
        }

        // 1. Resolve known alias (case-insensitive).
        let resolved = Self.aliases[rawName.lowercased()] ?? rawName

        // 2. Exact match in each search root.
        for root in Self.searchRoots {
            let url = URL(fileURLWithPath: "\(root)/\(resolved).app")
            if FileManager.default.fileExists(atPath: url.path) {
                return await open(url, displayName: resolved)
            }
        }

        // 3. Fuzzy fallback: scan /Applications and /System/Applications for
        //    any bundle whose filename starts with or contains the resolved name.
        //    Catches version-suffixed names like "CleanMyMac X.app".
        let fuzzyRoots = ["/Applications", "/System/Applications"]
        for root in fuzzyRoots {
            if let url = fuzzyFind(name: resolved, in: root) {
                return await open(url, displayName: resolved)
            }
        }

        return ToolResult(
            toolName: name,
            success: false,
            message: "'\(resolved)' does not appear to be installed.",
            payload: [:]
        )
    }

    // MARK: - Helpers

    private func fuzzyFind(name: String, in directory: String) -> URL? {
        let lower = name.lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        // Prefer entries that start with the name, then fall back to contains.
        let candidates = entries.filter { $0.hasSuffix(".app") }
        let startsWith = candidates.first { $0.lowercased().hasPrefix(lower) }
        let contains   = candidates.first { $0.lowercased().contains(lower) }
        guard let match = startsWith ?? contains else { return nil }
        return URL(fileURLWithPath: "\(directory)/\(match)")
    }

    private func open(_ url: URL, displayName: String) async -> ToolResult {
        let ok = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        return ToolResult(
            toolName: name,
            success: ok,
            message: ok ? "Opened \(displayName)." : "Could not open \(displayName).",
            payload: ["launchedApp": displayName]
        )
    }
}

struct FileSearchTool: ToolProtocol {
    let name = "file_search_tool"
    let description = "Searches common user folders for filenames."
    let inputSchema = ["query": "String"]
    let resultSchema = ["bestPath": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let query = arguments["query"], !query.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing query.", payload: [:])
        }

        let urls = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop"),
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents"),
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")]

        for root in urls {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    return ToolResult(
                        toolName: name,
                        success: true,
                        message: "Found \(url.lastPathComponent).",
                        payload: ["bestPath": url.path]
                    )
                }
            }
        }
        return ToolResult(toolName: name, success: false, message: "No file found for '\(query)'.", payload: [:])
    }
}

struct FileOpenTool: ToolProtocol {
    let name = "file_open_tool"
    let description = "Opens a file at a given path."
    let inputSchema = ["path": "String"]
    let resultSchema = ["openedPath": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let path = arguments["path"], !path.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing path.", payload: [:])
        }
        let ok = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return ToolResult(
            toolName: name,
            success: ok,
            message: ok ? "Opened file." : "Unable to open file.",
            payload: ["openedPath": path]
        )
    }
}

struct FolderCreateTool: ToolProtocol {
    let name = "folder_create_tool"
    let description = "Creates a folder at a target path."
    let inputSchema = ["path": "String"]
    let resultSchema = ["createdPath": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired

    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let path = arguments["path"], !path.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing path.", payload: [:])
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return ToolResult(toolName: name, success: true, message: "Created folder.", payload: ["createdPath": path])
        } catch {
            return ToolResult(toolName: name, success: false, message: "Failed to create folder: \(error.localizedDescription)", payload: [:])
        }
    }
}

struct BrowserOpenURLTool: ToolProtocol {
    let name = "browser_open_url_tool"
    let description = "Opens a URL in the default browser."
    let inputSchema = ["url": "String"]
    let resultSchema = ["openedURL": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let value = arguments["url"], let url = URL(string: value) else {
            return ToolResult(toolName: name, success: false, message: "Invalid URL.", payload: [:])
        }
        let ok = NSWorkspace.shared.open(url)
        return ToolResult(toolName: name, success: ok, message: ok ? "Opened URL." : "Could not open URL.", payload: ["openedURL": value])
    }
}

struct FileMoveTool: ToolProtocol {
    let name = "file_move_tool"
    let description = "Moves a file from source to destination."
    let inputSchema = ["sourcePath": "String", "destinationPath": "String"]
    let resultSchema = ["destinationPath": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: false, message: "Not yet implemented.", payload: [:]) }
}

struct FileRenameTool: ToolProtocol {
    let name = "file_rename_tool"
    let description = "Renames a file."
    let inputSchema = ["path": "String", "newName": "String"]
    let resultSchema = ["newPath": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: false, message: "Not yet implemented.", payload: [:]) }
}

struct FileZipTool: ToolProtocol {
    let name = "file_zip_tool"
    let description = "Creates a zip archive from files."
    let inputSchema = ["path": "String"]
    let resultSchema = ["zipPath": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: false, message: "Not yet implemented.", payload: [:]) }
}

struct WebSearchTool: ToolProtocol {
    let name = "web_search_tool"
    let description = "Searches the web with default browser."
    let inputSchema = ["query": "String"]
    let resultSchema = ["query": "String"]
    let safetyLevel: SafetyLevel = .safe
    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let query = arguments["query"], !query.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing query.", payload: [:])
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://www.google.com/search?q=\(encoded)")!
        let ok = NSWorkspace.shared.open(url)
        return ToolResult(toolName: name, success: ok, message: ok ? "Opened web search." : "Could not run search.", payload: ["query": query])
    }
}

struct ClipboardReadTool: ToolProtocol {
    let name = "clipboard_read_tool"
    let description = "Reads plaintext from clipboard."
    let inputSchema: [String: String] = [:]
    let resultSchema = ["text": "String"]
    let safetyLevel: SafetyLevel = .safe
    func execute(arguments: [String : String]) async throws -> ToolResult {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return ToolResult(toolName: name, success: true, message: "Read clipboard.", payload: ["text": text])
    }
}

struct ClipboardWriteTool: ToolProtocol {
    let name = "clipboard_write_tool"
    let description = "Writes plaintext to clipboard."
    let inputSchema = ["text": "String"]
    let resultSchema = ["written": "Bool"]
    let safetyLevel: SafetyLevel = .safe
    func execute(arguments: [String : String]) async throws -> ToolResult {
        NSPasteboard.general.clearContents()
        let value = arguments["text"] ?? ""
        NSPasteboard.general.setString(value, forType: .string)
        return ToolResult(toolName: name, success: true, message: "Copied text to clipboard.", payload: ["written": "true"])
    }
}

struct NoteCreateTool: ToolProtocol {
    let name = "note_create_tool"
    let description = "Creates a note (MVP placeholder)."
    let inputSchema = ["title": "String", "body": "String"]
    let resultSchema = ["noteId": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: true, message: "Mock note created.", payload: ["noteId": UUID().uuidString]) }
}

struct CalendarCreateTool: ToolProtocol {
    let name = "calendar_create_tool"
    let description = "Creates calendar event (MVP placeholder)."
    let inputSchema = ["title": "String", "date": "String"]
    let resultSchema = ["eventId": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: true, message: "Mock calendar event created.", payload: ["eventId": UUID().uuidString]) }
}

struct EmailDraftTool: ToolProtocol {
    let name = "email_draft_tool"
    let description = "Creates an email draft (MVP placeholder)."
    let inputSchema = ["to": "String", "subject": "String", "body": "String"]
    let resultSchema = ["draftId": "String"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult { ToolResult(toolName: name, success: true, message: "Mock email draft created.", payload: ["draftId": UUID().uuidString]) }
}

struct FinderRevealTool: ToolProtocol {
    let name = "finder_reveal_tool"
    let description = "Reveals file in Finder."
    let inputSchema = ["path": "String"]
    let resultSchema = ["path": "String"]
    let safetyLevel: SafetyLevel = .safe
    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(toolName: name, success: false, message: "Missing path.", payload: [:])
        }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        return ToolResult(toolName: name, success: true, message: "Revealed in Finder.", payload: ["path": path])
    }
}

struct SystemDNDTool: ToolProtocol {
    let name = "system_dnd_tool"
    let description = "Toggles Do Not Disturb (placeholder)."
    let inputSchema = ["enabled": "Bool"]
    let resultSchema = ["enabled": "Bool"]
    let safetyLevel: SafetyLevel = .confirmationRequired
    func execute(arguments: [String : String]) async throws -> ToolResult {
        ToolResult(toolName: name, success: true, message: "DND integration is mocked in MVP.", payload: ["enabled": arguments["enabled"] ?? "true"])
    }
}

// MARK: - Mail / Document / Attachment tools

struct MailSendTool: ToolProtocol {
    let name = "mail_send_tool"
    let description = "Composes an email in the default mail app via mailto: URL scheme."
    let inputSchema = [
        "to":             "String — recipient address",
        "subject":        "String — email subject",
        "body":           "String — email body",
        "attachmentPath": "String — optional local file path to attach"
    ]
    let resultSchema  = ["opened": "Bool"]
    let safetyLevel: SafetyLevel = .confirmationRequired

    func execute(arguments: [String: String]) async throws -> ToolResult {
        var components      = URLComponents()
        components.scheme   = "mailto"
        components.path     = arguments["to"] ?? ""
        var items: [URLQueryItem] = []
        if let subject = arguments["subject"], !subject.isEmpty {
            items.append(URLQueryItem(name: "subject", value: subject))
        }
        if let body = arguments["body"], !body.isEmpty {
            items.append(URLQueryItem(name: "body", value: body))
        }
        // Note: standard mailto: does not support attachments; attachment path
        // is stored in the payload so a future native Mail integration can use it.
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else {
            return ToolResult(toolName: name, success: false, message: "Could not build mailto URL.", payload: [:])
        }
        let ok = NSWorkspace.shared.open(url)
        return ToolResult(
            toolName: name,
            success: ok,
            message: ok ? "Opened Mail composer." : "Failed to open Mail.",
            payload: [
                "opened":         "\(ok)",
                "attachmentPath": arguments["attachmentPath"] ?? ""
            ]
        )
    }
}

struct PDFCreateTool: ToolProtocol {
    let name = "pdf_create_tool"
    let description = "Creates a PDF from plain-text or markdown content and saves it to savePath."
    let inputSchema = [
        "content":  "String — text content to render",
        "filename": "String — output filename (without .pdf extension is fine)",
        "savePath": "String — directory path where the PDF should be saved"
    ]
    let resultSchema  = ["savedPath": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let content  = arguments["content"],
              let filename = arguments["filename"],
              let savePath = arguments["savePath"] else {
            return ToolResult(toolName: name, success: false, message: "Missing required arguments.", payload: [:])
        }

        let baseName = filename.hasSuffix(".pdf") ? filename : "\(filename).pdf"
        let dirURL   = URL(fileURLWithPath: savePath, isDirectory: true)
        let fileURL  = dirURL.appendingPathComponent(baseName)

        guard let pdfData = renderTextAsPDF(content) else {
            return ToolResult(toolName: name, success: false, message: "Failed to render PDF.", payload: [:])
        }

        do {
            try pdfData.write(to: fileURL)
            return ToolResult(toolName: name, success: true, message: "PDF saved.", payload: ["savedPath": fileURL.path])
        } catch {
            return ToolResult(toolName: name, success: false, message: "Write error: \(error.localizedDescription)", payload: [:])
        }
    }

    // MARK: CoreText-based PDF renderer (no UIKit / NSTextView required)

    private func renderTextAsPDF(_ text: String) -> Data? {
        let pageWidth:  CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin:     CGFloat = 72
        let contentW = pageWidth - 2 * margin

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]
        let attrStr      = NSAttributedString(string: text, attributes: attrs)
        let framesetter  = CTFramesetterCreateWithAttributedString(attrStr)

        let mutableData = NSMutableData()
        var mediaBox    = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let context  = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var charIndex = 0
        let totalChars = attrStr.length

        repeat {
            context.beginPDFPage(nil)

            let contentRect = CGRect(x: margin, y: margin, width: contentW, height: pageHeight - 2 * margin)
            let path = CGMutablePath()
            path.addRect(contentRect)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: charIndex, length: 0),
                path,
                nil
            )

            // CoreText draws with origin at bottom-left; flip the context.
            context.saveGState()
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)
            CTFrameDraw(frame, context)
            context.restoreGState()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            charIndex += visible.length

            context.endPDFPage()
        } while charIndex < totalChars

        context.closePDF()
        return mutableData as Data
    }
}

struct FileAttachTool: ToolProtocol {
    let name = "file_attach_tool"
    let description = "Copies a file to a destination folder, useful for preparing email attachments."
    let inputSchema = [
        "path":        "String — source file path",
        "destination": "String — destination directory or full file path"
    ]
    let resultSchema  = ["copiedPath": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path        = arguments["path"],
              let destination = arguments["destination"] else {
            return ToolResult(toolName: name, success: false, message: "Missing path or destination.", payload: [:])
        }

        let srcURL  = URL(fileURLWithPath: path)
        var destURL = URL(fileURLWithPath: destination)

        // If destination is a directory, keep the original filename.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination, isDirectory: &isDir), isDir.boolValue {
            destURL = destURL.appendingPathComponent(srcURL.lastPathComponent)
        }

        do {
            try FileManager.default.copyItem(at: srcURL, to: destURL)
            return ToolResult(toolName: name, success: true, message: "File copied.", payload: ["copiedPath": destURL.path])
        } catch {
            return ToolResult(toolName: name, success: false, message: "Copy failed: \(error.localizedDescription)", payload: [:])
        }
    }
}
