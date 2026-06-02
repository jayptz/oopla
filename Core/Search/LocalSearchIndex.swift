import AppKit
import Foundation

// MARK: - LocalSearchIndex

final class LocalSearchIndex: SearchProviding {

    /// Keeps the in-flight Spotlight query alive until it finishes or is cancelled.
    private var activeSpotlight: SpotlightState?

    // MARK: - Entry point

    func search(query: String) async -> [SearchResultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            activeSpotlight?.cancel()
            activeSpotlight = nil
            return await emptyQuerySuggestions()
        }

        // Each new keystroke cancels any in-flight Spotlight query.
        activeSpotlight?.cancel()
        activeSpotlight = nil

        let words = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Natural-language guard: queries with more than 3 words are almost
        // certainly not launcher commands. Run only the app search, and only
        // keep results where a word in the query EXACTLY matches the app name.
        // Everything else is left to Claude so the sidebar stays clean.
        if words.count > 3 {
            let appResults = await searchApps(query: q)
            var results = appResults.filter { item in
                words.contains { $0.lowercased() == item.title.lowercased() }
            }
            if let suggestion = aiIntentSuggestion(for: q) {
                results.insert(suggestion, at: 0)
            }
            return Array(results.prefix(6))
        }

        // Pure-computation results are synchronous and always rank highest.
        let computed = quickCompute(query: q)

        // I/O-bound searches run in parallel.
        async let apps  = searchApps(query: q)
        async let files = spotlightSearch(query: q)

        let appResults  = await apps
        let fileResults = await files
        let settings    = searchSystemSettings(query: q)

        // Merge in display priority order, then re-sort and cap.
        let all = computed + appResults + settings + fileResults
        return all
            .sorted { $0.score > $1.score }
            .prefix(15)
            .map { $0 }
    }

    // MARK: - Calculator + unit conversion

    private func quickCompute(query: String) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        if let conv = detectUnitConversion(query: query) { results.append(conv) }
        if let calc = evaluateExpression(query: query) { results.append(calc) }
        return results
    }

    /// Evaluates basic arithmetic using NSExpression.
    /// Only fires on strings that are exclusively digits, spaces, and +−×÷ operators.
    private func evaluateExpression(query: String) -> SearchResultItem? {
        let q = query.trimmingCharacters(in: .whitespaces)

        // Must have at least one digit and one operator.
        guard q.contains(where: { $0.isNumber }),
              q.contains(where: { "+-*/%" .contains($0) }) else { return nil }

        // Whitelist: only safe math characters to avoid NSExpression crashes.
        let safeSet = CharacterSet.decimalDigits
            .union(.init(charactersIn: " +-*/%.()"))
        guard q.unicodeScalars.allSatisfy({ safeSet.contains($0) }) else { return nil }

        // NSExpression uses standard operator precedence.
        let expr  = NSExpression(format: q)
        guard let raw = expr.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }
        let d = raw.doubleValue
        guard d.isFinite else { return nil }

        let str = d.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", d)
            : String(format: "%g", d)

        return SearchResultItem(
            title: str,
            subtitle: "Calculator — tap to copy",
            kind: .action,
            score: 1.0,
            metadata: ["copyValue": str]
        )
    }

    // MARK: - Unit conversion

    private struct Conversion {
        let value: Double; let unit: String
    }

    private func detectUnitConversion(query: String) -> SearchResultItem? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = #"^([\d.]+)\s*([a-z]+)\s+(?:to|in)\s+([a-z]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(
                in: q,
                range: NSRange(q.startIndex..., in: q)
              ),
              m.numberOfRanges == 4 else { return nil }

        let ns = q as NSString
        let valueStr = ns.substring(with: m.range(at: 1))
        let from     = ns.substring(with: m.range(at: 2))
        let to       = ns.substring(with: m.range(at: 3))

        guard let v = Double(valueStr),
              let c = convertUnits(value: v, from: from, to: to) else { return nil }

        let resultStr = c.value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.2f", c.value)
            : String(format: "%g", c.value)
        let title = "\(resultStr) \(c.unit)"

        return SearchResultItem(
            title: title,
            subtitle: "Unit conversion — tap to copy",
            kind: .action,
            score: 1.0,
            metadata: ["copyValue": title]
        )
    }

    private func convertUnits(value: Double, from: String, to: String) -> Conversion? {
        switch (from, to) {
        case ("km",         "miles"), ("km",        "mi"):     return .init(value: value * 0.621371,   unit: "miles")
        case ("miles",      "km"),    ("mi",         "km"):     return .init(value: value * 1.60934,    unit: "km")
        case ("kg",         "lbs"),   ("kg",         "lb"):     return .init(value: value * 2.20462,    unit: "lbs")
        case ("lbs",        "kg"),    ("lb",         "kg"):     return .init(value: value / 2.20462,    unit: "kg")
        case ("celsius",    "fahrenheit"), ("c",     "f"):      return .init(value: value * 9/5 + 32,   unit: "°F")
        case ("fahrenheit", "celsius"),   ("f",      "c"):      return .init(value: (value - 32) * 5/9, unit: "°C")
        case ("meters",     "feet"),  ("m",          "ft"):     return .init(value: value * 3.28084,    unit: "feet")
        case ("feet",       "meters"), ("ft",        "m"):      return .init(value: value / 3.28084,    unit: "meters")
        case ("liters",     "gallons"), ("l",        "gal"):    return .init(value: value * 0.264172,   unit: "gallons")
        case ("gallons",    "liters"), ("gal",       "l"):      return .init(value: value / 0.264172,   unit: "liters")
        default: return nil
        }
    }

    // MARK: - App search

    private func searchApps(query: String) async -> [SearchResultItem] {
        // All directories that can contain .app bundles.
        let home = FileManager.default.homeDirectoryForCurrentUser
        var appDirs: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appending(path: "Applications"),
        ]

        // One level of subdirectories in /Applications (e.g. Utilities, Setapp).
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for sub in subs {
                let vals = try? sub.resourceValues(forKeys: [.isDirectoryKey])
                if vals?.isDirectory == true && sub.pathExtension != "app" {
                    appDirs.append(sub)
                }
            }
        }

        let q = query.lowercased()
        var seen  = Set<String>()
        var results: [SearchResultItem] = []

        for dir in appDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in items where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard !seen.contains(name), fuzzyMatch(query: q, target: name) else { continue }
                seen.insert(name)
                results.append(SearchResultItem(
                    title: name,
                    subtitle: "Application",
                    kind: .app,
                    path: url.path,
                    score: appScore(query: q, target: name.lowercased())
                ))
            }
        }

        return results.sorted { $0.score > $1.score }.prefix(8).map { $0 }
    }

    // MARK: - System settings

    private static let systemSettings: [(label: String, url: String, keywords: [String])] = [
        ("Wi-Fi",             "x-apple.systempreferences:com.apple.wifi-settings-extension",                ["wifi", "network", "internet", "wireless"]),
        ("Bluetooth",         "x-apple.systempreferences:com.apple.BluetoothSettings",                      ["bluetooth", "bt", "headphones"]),
        ("Displays",          "x-apple.systempreferences:com.apple.Displays-Settings.extension",            ["display", "screen", "brightness", "resolution", "monitor"]),
        ("Battery",           "x-apple.systempreferences:com.apple.Battery-Settings.extension",             ["battery", "power", "charging", "energy"]),
        ("Notifications",     "x-apple.systempreferences:com.apple.preference.notifications",               ["notifications", "alerts", "banners", "badges"]),
        ("Privacy & Security","x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",     ["privacy", "security", "permissions", "camera", "microphone"]),
        ("Sound",             "x-apple.systempreferences:com.apple.Sound-Settings.extension",               ["sound", "audio", "volume", "microphone", "speakers"]),
        ("Appearance",        "x-apple.systempreferences:com.apple.Appearance-Settings.extension",          ["appearance", "dark mode", "light mode", "theme", "accent"]),
        ("Storage",           "x-apple.systempreferences:com.apple.settings.Storage",                       ["storage", "disk", "space", "icloud", "clean"]),
        ("Focus",             "x-apple.systempreferences:com.apple.Focus-Settings.extension",               ["focus", "dnd", "do not disturb", "sleep"]),
    ]

    private func searchSystemSettings(query: String) -> [SearchResultItem] {
        let q = query.lowercased()
        return Self.systemSettings.compactMap { setting in
            let labelMatch   = setting.label.lowercased().contains(q)
            let keywordMatch = setting.keywords.contains { kw in kw.contains(q) || q.contains(kw) }
            guard labelMatch || keywordMatch else { return nil }
            return SearchResultItem(
                title: setting.label,
                subtitle: "System Settings",
                kind: .action,
                score: 0.9,
                metadata: ["url": setting.url]
            )
        }
    }

    // MARK: - NSMetadataQuery (Spotlight index)

    private func spotlightSearch(query: String) async -> [SearchResultItem] {
        guard query.count >= 2 else { return [] }

        // Cancel any previous query so its continuation is always resumed.
        activeSpotlight?.cancel()
        activeSpotlight = nil

        return await withCheckedContinuation { continuation in
            let state = SpotlightState(query: query) { [weak self] results in
                self?.activeSpotlight = nil
                continuation.resume(returning: results)
            }
            self.activeSpotlight = state
            state.start()
        }
    }

    // MARK: - AI intent suggestions (long natural-language queries)

    private func aiIntentSuggestion(for query: String) -> SearchResultItem? {
        let q = query.lowercased()
        let mentionsResume = q.contains("resume") || q.contains(" cv")
        let mentionsTailor = ["tailor", "customize", "customise", "adapt", "adjust", "rewrite"]
            .contains { q.contains($0) }

        if mentionsResume && mentionsTailor {
            return SearchResultItem(
                title: "Tailor resume for this job",
                subtitle: "Press Enter — reads the job on screen and your resume",
                kind: .aiAction,
                score: 1.0
            )
        }

        let explainPhrases = [
            "explain what's on", "explain what is on", "explain this", "explain my screen",
            "study help", "help me understand", "youtube video"
        ]
        if explainPhrases.contains(where: { q.contains($0) }) {
            return SearchResultItem(
                title: "Explain what's on screen",
                subtitle: "Press Enter — reads your screen and shows an explanation",
                kind: .aiAction,
                score: 1.0
            )
        }

        let visionPhrases = [
            "screen", "look at", "what's on", "this job", "job application",
            "this email", "see my", "on screen"
        ]
        if visionPhrases.contains(where: { q.contains($0) }) && mentionsResume {
            return SearchResultItem(
                title: "AI: \(query)",
                subtitle: "Press Enter — uses screen context",
                kind: .aiAction,
                score: 0.95
            )
        }

        return nil
    }

    // MARK: - Empty query suggestions

    /// Shows running apps + recent documents when the bar opens with no text.
    private func emptyQuerySuggestions() async -> [SearchResultItem] {
        var results: [SearchResultItem] = []

        // Running foreground apps.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .prefix(3)
        for app in running {
            guard let name = app.localizedName else { continue }
            results.append(SearchResultItem(
                title: name,
                subtitle: "Open",
                kind: .app,
                path: app.bundleURL?.path,
                score: 0.65
            ))
        }

        // Recent documents from NSDocumentController.
        let recentDocs = await NSDocumentController.shared.recentDocumentURLs.prefix(5)
        for url in recentDocs {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = vals?.isDirectory ?? false
            results.append(SearchResultItem(
                title: url.lastPathComponent,
                subtitle: "Recent • \(url.deletingLastPathComponent().lastPathComponent)",
                kind: isDir ? .folder : .file,
                path: url.path,
                score: 0.6
            ))
        }

        return Array(results.prefix(6))
    }

    // MARK: - Scoring helpers

    /// Returns true if the target (app name) contains the query, or if the
    /// query is a prefix of any individual word in the target.
    ///
    /// NOTE: We intentionally do NOT check `q.contains(t)` (whether the query
    /// contains the app name), because a long natural-language query like
    /// "what is my screen showing" would then match any short app name whose
    /// letters happen to appear in the query string (e.g. "R.app" matches
    /// because "screen" contains the letter 'r').
    func fuzzyMatch(query: String, target: String) -> Bool {
        let q = query.lowercased()
        let t = target.lowercased()
        // App name contains the query term.
        if t.contains(q) { return true }
        // Partial word prefix: "spo" matches "Spotify Music" via the word "Spotify".
        return t.components(separatedBy: .whitespaces).contains { $0.hasPrefix(q) }
    }

    private func appScore(query: String, target: String) -> Double {
        if target == query                               { return 1.0  }
        if target.hasPrefix(query)                       { return 0.95 }
        if target.contains(query)                        { return 0.88 }
        // Prefix match on any word within a multi-word name.
        if target.components(separatedBy: .whitespaces)
            .contains(where: { $0.hasPrefix(query) })    { return 0.85 }
        return 0.6
    }
}

// MARK: - SpotlightState

/// Manages an NSMetadataQuery lifecycle across the async boundary.
/// Must be retained by `LocalSearchIndex.activeSpotlight` until `finish` runs.
private final class SpotlightState {
    private let mdQuery = NSMetadataQuery()
    private let rawQuery: String
    private let onComplete: ([SearchResultItem]) -> Void
    private var observer: NSObjectProtocol?
    private var finished = false

    init(query: String, onComplete: @escaping ([SearchResultItem]) -> Void) {
        self.rawQuery = query
        self.onComplete = onComplete
    }

    deinit {
        cancel()
    }

    func start() {
        mdQuery.predicate = NSPredicate(
            format: "%K CONTAINS[cd] %@",
            NSMetadataItemDisplayNameKey,
            rawQuery
        )
        mdQuery.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        mdQuery.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)
        ]

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mdQuery,
            queue: .main
        ) { [weak self] _ in
            self?.finish(with: self?.gatherResults() ?? [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish(with: self?.gatherResults() ?? [])
        }

        DispatchQueue.main.async { [weak self] in
            self?.mdQuery.start()
        }
    }

    /// Stops the query and resumes the waiter with no results.
    func cancel() {
        finish(with: [])
    }

    private func finish(with results: [SearchResultItem]) {
        guard !finished else { return }
        finished = true

        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }

        if mdQuery.isStarted {
            mdQuery.stop()
        }

        onComplete(results)
    }

    private func gatherResults() -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        mdQuery.disableUpdates()

        let count = min(mdQuery.resultCount, 15)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)

        for i in 0..<count {
            guard let item = mdQuery.result(at: i) as? NSMetadataItem else { continue }

            guard let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String,
                  !name.hasPrefix(".")
            else { continue }

            let path        = item.value(forAttribute: NSMetadataItemPathKey) as? String
            let lastUsed    = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String ?? ""

            let kind: ResultKind
            if contentType == "public.folder"
                || contentType.hasSuffix(".folder")
                || contentType == "public.directory" {
                kind = .folder
            } else {
                kind = .file
            }

            let isRecent = lastUsed.map { $0 > sevenDaysAgo } ?? false
            let score: Double = isRecent ? 0.85 : 0.75

            let ext = (name as NSString).pathExtension.uppercased()
            let dateLabel: String
            if let used = lastUsed {
                dateLabel = RelativeDateTimeFormatter().localizedString(for: used, relativeTo: Date())
            } else {
                dateLabel = "Unknown"
            }
            let typeLabel = ext.isEmpty ? "File" : ext

            results.append(SearchResultItem(
                title: name,
                subtitle: "\(typeLabel) • \(dateLabel)",
                kind: kind,
                path: path,
                score: score
            ))
        }

        mdQuery.enableUpdates()
        return results
    }
}
