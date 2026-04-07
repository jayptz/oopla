import SwiftUI

struct ExecutionView: View {
    let state: CommandExecutionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Execution")
                    .font(.headline)
                Spacer()
                Text(state.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let plan = state.currentPlan {
                Text(plan.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if state.steps.isEmpty {
                Text("No steps yet.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(state.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        statusDot(for: step.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.toolCall.toolName)
                                .font(.subheadline.weight(.semibold))
                            Text(step.toolCall.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            switch step.state {
                            case .succeeded(let message), .failed(let message):
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            case .pending, .running:
                                EmptyView()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(for state: ExecutionStepState.State) -> some View {
        switch state {
        case .pending:
            Circle().fill(.gray).frame(width: 8, height: 8)
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }
}
