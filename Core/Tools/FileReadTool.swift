import AppKit
import Foundation
import PDFKit

// MARK: - FileReadTool

struct FileReadTool: ToolProtocol {
    let name = "file_read_tool"
    let description = "Reads and extracts text from a file at the given path (.txt, .md, .pdf, .docx)."
    let inputSchema  = ["path": "String — absolute file path"]
    let resultSchema = ["content": "String — extracted text (capped at ~8000 characters)"]
    let safetyLevel: SafetyLevel = .safe

    private static let maxCharacters = 8_000

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"], !path.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "Missing path.", payload: [:])
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(toolName: name, success: false, message: "File not found.", payload: [:])
        }

        let ext = url.pathExtension.lowercased()
        let text: String?
        switch ext {
        case "txt", "md", "markdown":
            text = readPlainText(url: url)
        case "pdf":
            text = readPDF(url: url)
        case "docx":
            text = readDOCX(url: url)
        default:
            return ToolResult(
                toolName: name,
                success: false,
                message: "Unsupported file type '.\(ext)'. Supported: .txt, .md, .pdf, .docx",
                payload: [:]
            )
        }

        guard var content = text, !content.isEmpty else {
            return ToolResult(toolName: name, success: false, message: "No text could be extracted.", payload: [:])
        }

        let truncated = content.count > Self.maxCharacters
        if truncated {
            content = String(content.prefix(Self.maxCharacters))
        }

        var message = "Read \(content.count) characters from \(url.lastPathComponent)."
        if truncated { message += " (truncated to \(Self.maxCharacters) chars)" }

        return ToolResult(
            toolName: name,
            success: true,
            message: message,
            payload: ["content": content]
        )
    }

    // MARK: - Format readers

    private func readPlainText(url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func readPDF(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.string
    }

    private func readDOCX(url: URL) -> String? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", url.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let xmlURL = tempDir.appendingPathComponent("word/document.xml")
            guard let xml = try? String(contentsOf: xmlURL, encoding: .utf8) else { return nil }
            return stripXMLTags(xml)
        } catch {
            return nil
        }
    }

    private func stripXMLTags(_ xml: String) -> String {
        var result = xml
        // Paragraph breaks.
        result = result.replacingOccurrences(of: "</w:p>", with: "\n")
        // Strip remaining tags.
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Decode common entities.
        result = result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
        // Collapse excessive whitespace.
        let lines = result.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
