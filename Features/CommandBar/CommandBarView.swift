import SwiftUI

struct CommandBarView: View {
    @EnvironmentObject private var orchestrator: CommandOrchestrator
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CommandBarViewModel()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            // Spotlight-style pill input
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Ask Oopla to do anything on your Mac...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onChange(of: viewModel.query) { _ in
                        viewModel.onQueryChanged()
                    }
                    .onSubmit {
                        Task { await viewModel.executeCurrentSelection(results: orchestrator.searchResults) }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())

            // Dropdown list directly under the pill (plus inline execution feedback)
            VStack(spacing: 0) {
                ForEach(Array(orchestrator.searchResults.enumerated()), id: \.element.id) { index, item in
                    ResultRow(item: item, isSelected: index == viewModel.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            Task { await viewModel.executeCurrentSelection(results: orchestrator.searchResults) }
                        }
                        .padding(.horizontal, 4)
                }

                if orchestrator.executionState.currentPlan != nil || !orchestrator.executionState.steps.isEmpty {
                    Divider().padding(.vertical, 8)
                    ExecutionView(state: orchestrator.executionState)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }

                if let error = orchestrator.latestError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
            viewModel.selectedIndex = min(viewModel.selectedIndex + 1, orchestrator.searchResults.count - 1)
        case .up:
            viewModel.selectedIndex = max(viewModel.selectedIndex - 1, 0)
        default:
            break
        }
    }
}

private struct ResultRow: View {
    let item: SearchResultItem
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: symbol(for: item.kind))
                .foregroundStyle(color(for: item.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.kind.rawValue.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func symbol(for kind: ResultKind) -> String {
        switch kind {
        case .app: "app.fill"
        case .file: "doc.fill"
        case .folder: "folder.fill"
        case .action: "bolt.fill"
        case .aiAction: "sparkles"
        case .web: "globe"
        }
    }

    private func color(for kind: ResultKind) -> Color {
        switch kind {
        case .aiAction: .cyan
        case .action: .orange
        default: .secondary
        }
    }
}

private struct ConfirmationSheet: View {
    let plan: ActionPlan
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm action")
                .font(.title3.weight(.semibold))
            Text(plan.summary)
                .font(.subheadline)
            ForEach(plan.steps) { step in
                HStack(alignment: .top) {
                    Image(systemName: "chevron.right")
                    VStack(alignment: .leading) {
                        Text(step.toolName).font(.callout.weight(.semibold))
                        Text(step.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run", action: approve)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 420)
    }
}
