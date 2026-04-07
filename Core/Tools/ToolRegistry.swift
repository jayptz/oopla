import AppKit
import Foundation

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
                SystemDNDTool()
            ]
        )
    }
}

struct AppLauncherTool: ToolProtocol {
    let name = "app_launcher_tool"
    let description = "Launches a macOS application by name."
    let inputSchema = ["appName": "String"]
    let resultSchema = ["launchedApp": "String"]
    let safetyLevel: SafetyLevel = .safe

    func execute(arguments: [String : String]) async throws -> ToolResult {
        guard let appName = arguments["appName"], !appName.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing appName.", payload: [:])
        }
        let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            return ToolResult(
                toolName: name,
                success: false,
                message: "Could not find \(appName) in /Applications.",
                payload: ["launchedApp": appName]
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let ok = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        return ToolResult(
            toolName: name,
            success: ok,
            message: ok ? "Opened \(appName)." : "Could not open \(appName).",
            payload: ["launchedApp": appName]
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
