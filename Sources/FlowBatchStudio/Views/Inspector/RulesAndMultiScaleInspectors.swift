import FlowBatchCore
import SwiftUI

/// Dynamic predicate rule builder for the `Rules` sort node.
struct RulesInspectorView: View {
    @Bindable var store: WorkflowStore
    let node: WorkflowNode

    var body: some View {
        let matchAll = node.parameters["matchAll"]?.boolValue ?? true
        let rules = node.parameters["rules"]?.rulesValue ?? [FilterRule()]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Condition:", selection: Binding(
                    get: { matchAll },
                    set: { store.setParameter(nodeID: node.id, key: "matchAll", value: .bool($0), actionName: "Change Rule Match Mode") }
                )) {
                    Text("Match All").tag(true)
                    Text("Match Any").tag(false)
                }
                .controlSize(.small)

                Spacer()

                Button {
                    var next = rules
                    next.append(FilterRule())
                    store.setParameter(nodeID: node.id, key: "rules", value: .rules(next), actionName: "Add Rule")
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
            }

            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 5) {
                    Picker("", selection: Binding(
                        get: { rule.field },
                        set: { newField in
                            var next = rules
                            next[index].field = newField
                            store.setParameter(nodeID: node.id, key: "rules", value: .rules(next), actionName: "Edit Rule")
                        }
                    )) {
                        ForEach(RuleField.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 96)

                    Picker("", selection: Binding(
                        get: { rule.op },
                        set: { newOp in
                            var next = rules
                            next[index].op = newOp
                            store.setParameter(nodeID: node.id, key: "rules", value: .rules(next), actionName: "Edit Rule")
                        }
                    )) {
                        ForEach(RuleOperator.allCases, id: \.self) { op in
                            Text(op.rawValue).tag(op)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 92)

                    TextField("Value", text: Binding(
                        get: { rule.value },
                        set: { newVal in
                            var next = rules
                            next[index].value = newVal
                            store.setParameter(nodeID: node.id, key: "rules", value: .rules(next), actionName: "Edit Rule")
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                    Button {
                        var next = rules
                        next.remove(at: index)
                        store.setParameter(nodeID: node.id, key: "rules", value: .rules(next), actionName: "Remove Rule")
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rules.count <= 1)
                }
            }
        }
    }
}

/// Multi-branch scale builder for `Multi Scale`.
struct MultiScaleInspectorView: View {
    @Bindable var store: WorkflowStore
    let node: WorkflowNode

    var body: some View {
        let specs = node.parameters["scales"]?.scalesValue ?? [
            ScaleBranchSpec(label: "1x", scaleFactor: 0.5, suffix: ""),
            ScaleBranchSpec(label: "2x", scaleFactor: 1.0, suffix: "@2x")
        ]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scale Branches:")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    var next = specs
                    let n = next.count + 1
                    next.append(ScaleBranchSpec(label: "\(n)x", scaleFactor: Double(n) * 0.5, suffix: "@\(n)x"))
                    store.setParameter(nodeID: node.id, key: "scales", value: .scales(next), actionName: "Add Scale Branch")
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
            }

            ForEach(Array(specs.enumerated()), id: \.element.id) { idx, spec in
                HStack(spacing: 6) {
                    TextField("Label", text: Binding(
                        get: { spec.label },
                        set: { val in
                            var next = specs; next[idx].label = val
                            store.setParameter(nodeID: node.id, key: "scales", value: .scales(next), actionName: "Edit Scale")
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 52)

                    TextField("Factor", value: Binding(
                        get: { spec.scaleFactor },
                        set: { val in
                            var next = specs; next[idx].scaleFactor = max(0.05, val)
                            store.setParameter(nodeID: node.id, key: "scales", value: .scales(next), actionName: "Edit Scale")
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 60)

                    TextField("Suffix", text: Binding(
                        get: { spec.suffix },
                        set: { val in
                            var next = specs; next[idx].suffix = val
                            store.setParameter(nodeID: node.id, key: "scales", value: .scales(next), actionName: "Edit Scale")
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                    Button {
                        var next = specs
                        next.remove(at: idx)
                        store.setParameter(nodeID: node.id, key: "scales", value: .scales(next), actionName: "Remove Scale")
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(specs.count <= 1)
                }
            }
        }
    }
}
