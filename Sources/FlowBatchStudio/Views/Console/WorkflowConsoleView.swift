import FlowBatchCore
import SwiftUI

/// Collapsible execution console showing per-node logs, script stdout, warnings, and errors.
struct WorkflowConsoleView: View {
    @Bindable var store: WorkflowStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Workflow Console"))
                    .font(.caption.weight(.semibold))
                Text("(\(store.consoleEntries.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Clear")) {
                    store.clearRunLogs()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if store.consoleEntries.isEmpty {
                Text(String(localized: "No execution logs yet. Press ▶ to run the workflow."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.consoleEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(color(for: entry.level))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 4)

                                Text("[\(entry.nodeTitle)]")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for level: ConsoleLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
