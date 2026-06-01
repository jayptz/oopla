import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - CommandBarView

struct CommandBarView: View {
    @EnvironmentObject private var orchestrator: CommandOrchestrator
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CommandBarViewModel()
    @FocusState private var focused: Bool
    @Namespace private var glassNamespace
    @State private var isDragTarget = false

    private static let dropTypes: [UTType] = [
        .fileURL,
        .pdf,
        .plainText,
        UTType(filenameExtension: "docx")!
    ]

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 8) {

                // ── Dropped file chips ──────────────────────────────────
                if !viewModel.droppedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.droppedFiles, id: \.self) { url in
                                DroppedFileChip(url: url) {
                                    viewModel.removeDroppedFile(url)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                // ── Search input ────────────────────────────────────────
                ZStack {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.primary)

                        TextField("Ask Oopla to do anything on your Mac...", text: $viewModel.query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($focused)
                            .onChange(of: viewModel.query) { _ in
                                viewModel.onQueryChanged()
                            }
                            .onSubmit {
                                Task {
                                    await viewModel.executeCurrentSelection(results: orchestrator.searchResults)
                                }
                            }
                    }
                    .frame(height: 52)
                    .padding(.horizontal, 16)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 14))

                    if isDragTarget {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.cyan.opacity(0.85), lineWidth: 2)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.cyan.opacity(0.12))
                            )
                            .shadow(color: .cyan.opacity(0.35), radius: 8)

                        VStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title3)
                                .foregroundStyle(.cyan)
                            Text("Drop file here")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isDragTarget)

                // ── Results list ────────────────────────────────────────
                if !orchestrator.searchResults.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(
                            Array(orchestrator.searchResults.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            ResultRow(
                                item: item,
                                isSelected: index == viewModel.selectedIndex,
                                namespace: glassNamespace
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedIndex = index
                                Task { await viewModel.executeCurrentSelection(results: orchestrator.searchResults) }
                            }
                        }
                    }
                    .animation(
                        .spring(response: 0.25, dampingFraction: 0.82),
                        value: viewModel.selectedIndex
                    )
                    .padding(.horizontal, 4)
                }

                // ── Execution feedback ──────────────────────────────────
                if orchestrator.executionState.currentPlan != nil
                    || !orchestrator.executionState.steps.isEmpty
                    || orchestrator.executionState.explanation != nil
                {
                    Divider().padding(.horizontal, 8)

                    ExecutionView(state: orchestrator.executionState)
                        .padding(12)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
                }

                // ── Inline error ────────────────────────────────────────
                if let error = orchestrator.latestError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
            .padding(12)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20))
            .onDrop(of: Self.dropTypes, isTargeted: $isDragTarget) { providers in
                viewModel.handleDrop(providers: providers)
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            viewModel.bind(orchestrator: orchestrator)
            viewModel.onQueryChanged()
            focused = true
        }
        .sheet(item: Binding<ActionPlan?>(
            get: { orchestrator.pendingConfirmation },
            set: { _ in }
        )) { plan in
            ConfirmationSheet(
                plan: plan,
                approve: { Task { await orchestrator.approvePendingPlan() } },
                cancel: { orchestrator.cancelPendingPlan() }
            )
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand {
            appState.isCommandBarVisible = false
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !orchestrator.searchResults.isEmpty else { return }
        switch direction {
        case .down:
            viewModel.selectedIndex = min(
                viewModel.selectedIndex + 1,
                orchestrator.searchResults.count - 1
            )
        case .up:
            viewModel.selectedIndex = max(viewModel.selectedIndex - 1, 0)
        default:
            break
        }
    }
}

// MARK: - DroppedFileChip

private struct DroppedFileChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)

            Text(url.lastPathComponent)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: Capsule())
    }
}

// MARK: - ResultRow

private struct ResultRow: View {
    let item: SearchResultItem
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 10) {
            ResultIcon(item: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Kind badge — small glass pill
            Text(item.kind.rawValue.uppercased())
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassEffect(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isSelected {
                // The glass surface morphs between rows as selection changes.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.clear)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 10))
                    .glassEffectID("rowSelection", in: namespace)
            }
        }
    }
}

// MARK: - ResultIcon

private struct ResultIcon: View {
    let item: SearchResultItem

    var body: some View {
        Group {
            if let path = item.path,
               !path.isEmpty,
               item.kind == .app || item.kind == .file || item.kind == .folder
            {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.15))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fallbackSymbol: String {
        switch item.kind {
        case .app:      "app.fill"
        case .file:     "doc.fill"
        case .folder:   "folder.fill"
        case .action:   "bolt.fill"
        case .aiAction: "sparkles"
        case .web:      "globe"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .aiAction: .cyan
        case .action:   .orange
        case .app:      .blue
        case .folder:   .yellow
        default:        .secondary
        }
    }
}

// MARK: - ConfirmationSheet

private struct ConfirmationSheet: View {
    let plan: ActionPlan
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm action")
                        .font(.title3.weight(.semibold))
                    Text(plan.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Steps
                VStack(spacing: 6) {
                    ForEach(plan.steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isDestructive(step) ? .red : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.toolName)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(isDestructive(step) ? .red : .primary)
                                Text(step.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Actions
                HStack {
                    // Ghost cancel button
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Glass-filled run button
                    Button(action: approve) {
                        Text("Run")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .glassEffect(in: Capsule())
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(width: 440)
    }

    /// Flags tool calls that are potentially destructive for red tinting.
    private func isDestructive(_ step: ToolCall) -> Bool {
        let name = step.toolName.lowercased()
        return name.contains("delete") || name.contains("remove") || name.contains("overwrite")
    }
}
