import AppKit
import FlowBatchCore
import SwiftUI

/// Anchored popover inspector displaying the node header (title + circular blue enable toggle),
/// specialized or schema-driven parameter body, inline error banners, and failure policy selector.
struct NodeInspectorPopoverView: View {
    @Bindable var store: WorkflowStore
    let nodeID: UUID

    var body: some View {
        if let node = store.document.nodes.first(where: { $0.id == nodeID }) {
            VStack(alignment: .leading, spacing: 10) {
                // Header: Centered Title + Top-Right Blue Checkmark Toggle
                ZStack {
                    Text(node.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer()
                        Button {
                            store.setNodeEnabled(id: node.id, enabled: !node.isEnabled)
                        } label: {
                            Image(systemName: node.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(node.isEnabled ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(node.isEnabled ? String(localized: "Disable Node") : String(localized: "Enable Node"))
                    }
                }

                // Inline Execution Error Banner (with Photos Privacy deep link if needed)
                if let errMsg = store.nodeErrors[node.id] {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(errMsg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        if errMsg.localizedCaseInsensitiveContains("Photos") {
                            Button(String(localized: "Open Privacy Settings…")) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.mini)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                // Body
                Group {
                    if node.typeID == NodeTypeID.writeImages {
                        WriteImagesInspectorView(store: store, node: node)
                    } else if node.typeID == NodeTypeID.rules {
                        RulesInspectorView(store: store, node: node)
                    } else if node.typeID == NodeTypeID.multiScale {
                        MultiScaleInspectorView(store: store, node: node)
                    } else {
                        GenericNodeInspectorView(store: store, node: node)
                    }
                }

                Divider()

                // Per-Node Error Policy Footer
                HStack(spacing: 8) {
                    Text("On error:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { node.errorPolicy },
                        set: { store.setErrorPolicy(nodeID: node.id, policy: $0) }
                    )) {
                        ForEach(NodeErrorPolicy.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    Spacer()
                }
            }
            .padding(14)
            .frame(width: 344)
        }
    }
}
