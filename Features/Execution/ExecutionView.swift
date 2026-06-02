import AppKit
import SwiftUI

struct ExecutionView: View {
    let state: CommandExecutionState

    private var totalSteps: Int { state.steps.count }
    private var succeededCount: Int {
        state.steps.filter { if case .succeeded = $0.state { return true }; return false }.count
    }
    private var failedCount: Int {
        state.steps.filter { if case .failed = $0.state { return true }; return false }.count
    }
    private var runningIndex: Int? {
        state.steps.firstIndex { if case .running = $0.state { return true }; return false }
    }
    private var allSucceeded: Bool {
        totalSteps > 0 && succeededCount == totalSteps
    }
    private var isFinished: Bool {
        totalSteps > 0 && (succeededCount + failedCount) == totalSteps
    }
    private var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(succeededCount) / Double(totalSteps)
    }

    private var savedPDFPath: String? {
        for step in state.steps.reversed() {
            guard step.toolCall.toolName == "pdf_create_tool",
                  case .succeeded(let message) = step.state else { continue }
            return extractSavedPath(from: message)
        }
        return nil
    }

    private var displayExplanation: String? {
        if let text = state.explanation, !text.isEmpty { return text }
        if let text = state.currentPlan?.explanation, !text.isEmpty { return text }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let explanation = displayExplanation {
                explanationCard(explanation)
            }

            if !state.steps.isEmpty {
                progressHeader
            }

            if let plan = state.currentPlan, displayExplanation == nil {
                Text(plan.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if state.steps.isEmpty {
                if displayExplanation == nil {
                    Text("No steps yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(state.steps) { step in
                        checklistRow(step: step)
                    }
                }
            }

            if allSucceeded {
                completionCard
            }
        }
    }

    // MARK: - Explanation card

    private func explanationCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("✦ Explanation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if allSucceeded {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(headerStepText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                if !allSucceeded {
                    Text("\(Int(progressFraction * 100))%")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(allSucceeded ? Color.green : Color.accentColor)
                        .frame(width: max(geo.size.width * progressFraction, allSucceeded ? geo.size.width : 4))
                        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: progressFraction)
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerStepText: String {
        guard totalSteps > 0 else { return "Preparing…" }
        if let running = runningIndex {
            return "Step \(running + 1) of \(totalSteps)"
        }
        if isFinished {
            return failedCount > 0 ? "Finished with errors" : "Step \(totalSteps) of \(totalSteps)"
        }
        let next = min(succeededCount + failedCount + 1, totalSteps)
        return "Step \(next) of \(totalSteps)"
    }

    // MARK: - Checklist row

    private func checklistRow(step: ExecutionStepState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            checklistIcon(for: step.state)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(friendlyLabel(for: step.toolCall))
                    .font(step.state == .running ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(step.state == .running ? Color.primary : Color.primary.opacity(0.95))

                if !step.toolCall.reason.isEmpty, step.state != .running {
                    Text(step.toolCall.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                switch step.state {
                case .succeeded(let message):
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .pending, .running:
                    EmptyView()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func checklistIcon(for stepState: ExecutionStepState.State) -> some View {
        switch stepState {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Completion card

    private var completionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("Done!")
                .font(.title3.weight(.semibold))

            if let path = savedPDFPath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    revealInFinder(path: path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Friendly labels

    private func friendlyLabel(for toolCall: ToolCall) -> String {
        let args = toolCall.arguments
        switch toolCall.toolName {
        case "app_launcher_tool":
            let app = args["appName"] ?? "app"
            return "Opening \(app)"
        case "file_read_tool":
            if let path = args["path"], !path.isEmpty {
                return "Reading \((path as NSString).lastPathComponent)"
            }
            return "Reading file"
        case "resume_find_tool":
            return "Finding your resumes"
        case "pdf_create_tool":
            if let name = args["filename"], !name.isEmpty {
                return "Creating \(name)"
            }
            return "Creating PDF"
        case "browser_open_url_tool":
            return "Opening browser"
        case "web_search_tool":
            return "Searching the web"
        case "youtube_search_tool":
            if let q = args["query"], !q.isEmpty {
                return "Finding YouTube videos: \(q)"
            }
            return "Opening YouTube search"
        case "folder_create_tool":
            return "Creating folder"
        case "mail_send_tool":
            return "Sending email"
        case "file_open_tool":
            return "Opening file"
        case "file_search_tool":
            return "Searching for files"
        case "file_attach_tool":
            return "Preparing attachment"
        case "finder_reveal_tool":
            return "Revealing in Finder"
        case "clipboard_read_tool":
            return "Reading clipboard"
        case "clipboard_write_tool":
            return "Copying to clipboard"
        default:
            return toolCall.toolName.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Helpers

    private func extractSavedPath(from message: String) -> String? {
        let prefix = "PDF saved to "
        if message.hasPrefix(prefix) {
            var path = String(message.dropFirst(prefix.count))
            if path.hasSuffix(".") { path.removeLast() }
            return path.isEmpty ? nil : path
        }
        // Fallback: look for an absolute path in the message.
        let pattern = #"(/[^\s]+\.pdf)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[range])
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
