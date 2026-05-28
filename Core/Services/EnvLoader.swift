import Foundation

enum EnvLoader {
    /// Loads a key from .env file sitting next to the executable or in the project root.
    static func get(_ key: String) -> String? {
        // 1. Check real environment variables first (useful for CI / production)
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }

        // 2. Walk up from the bundle/executable to find .env
        let candidates: [URL] = [
            // swift run: .build/debug/Oopla → up 3 levels to project root
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".env"),
            // Fallback: next to executable
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(".env")
        ]

      for url in candidates {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        return nil
    }
}
