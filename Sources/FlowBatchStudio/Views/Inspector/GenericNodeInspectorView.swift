import AppKit
import FlowBatchCore
import SwiftUI

/// Schema-driven inspector form covering all parameter descriptor kinds cleanly.
struct GenericNodeInspectorView: View {
    @Bindable var store: WorkflowStore
    let node: WorkflowNode

    var body: some View {
        let descriptors = node.definition?.parameters ?? []
        if descriptors.isEmpty {
            Text(node.definition?.summary ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(descriptors) { param in
                    row(for: param)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for param: ParameterDescriptor) -> some View {
        let val = node.parameters[param.key] ?? param.defaultValue

        switch param.kind {
        case .toggle:
            Toggle(param.label, isOn: Binding(
                get: { val.boolValue ?? false },
                set: { store.setParameter(nodeID: node.id, key: param.key, value: .bool($0), actionName: "Toggle \(param.label)") }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

        case .text(let placeholder):
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                TextField(placeholder, text: Binding(
                    get: { val.stringValue ?? "" },
                    set: { store.setParameter(nodeID: node.id, key: param.key, value: .string($0), actionName: "Edit \(param.label)") }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }

        case .tokenField:
            HStack(alignment: .top, spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                    .padding(.top, 4)
                TokenPatternFieldView(pattern: val.stringValue ?? "") { updated in
                    store.setParameter(nodeID: node.id, key: param.key, value: .string(updated), actionName: "Edit \(param.label)")
                }
            }

        case .multilineCode:
            VStack(alignment: .leading, spacing: 4) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { val.stringValue ?? "" },
                    set: { store.setParameter(nodeID: node.id, key: param.key, value: .string($0), actionName: "Edit \(param.label)") }
                ))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }

        case .folderPath:
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        store.setParameter(nodeID: node.id, key: param.key, value: .string(url.path), actionName: "Choose Folder")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        let p = val.stringValue ?? ""
                        Text(p.isEmpty ? "Choose Folder…" : URL(fileURLWithPath: p).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
            }

        case .filePath(let exts):
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    if !exts.isEmpty {
                        panel.allowedContentTypes = exts.compactMap { .init(filenameExtension: $0) }
                    }
                    if panel.runModal() == .OK, let url = panel.url {
                        store.setParameter(nodeID: node.id, key: param.key, value: .string(url.path), actionName: "Choose File")
                    }
                } label: {
                    let p = val.stringValue ?? ""
                    Text(p.isEmpty ? "Choose File…" : URL(fileURLWithPath: p).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
            }

        case .slider(let minVal, let maxVal, _, let unit):
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                CoalescedDoubleSlider(
                    store: store,
                    nodeID: node.id,
                    key: param.key,
                    range: minVal...maxVal,
                    defaultValue: param.defaultValue.doubleValue ?? minVal,
                    actionName: "Adjust \(param.label)"
                )
                let num = val.doubleValue ?? minVal
                Text(String(format: "%.2f%@", num, unit.isEmpty ? "" : " \(unit)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }

        case .intSlider(let minVal, let maxVal, let unit):
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                CoalescedIntSlider(
                    store: store,
                    nodeID: node.id,
                    key: param.key,
                    range: minVal...maxVal,
                    defaultValue: param.defaultValue.intValue ?? minVal,
                    actionName: "Adjust \(param.label)"
                )
                let num = val.intValue ?? minVal
                Text("\(num)\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }

        case .picker(let options):
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { val.stringValue ?? options.first ?? "" },
                    set: { store.setParameter(nodeID: node.id, key: param.key, value: .string($0), actionName: "Change \(param.label)") }
                )) {
                    ForEach(options, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

        case .color:
            HStack(spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                let col = val.colorValue ?? .white
                ColorPicker("", selection: Binding(
                    get: { Color(red: col.red, green: col.green, blue: col.blue, opacity: col.alpha) },
                    set: { next in
                        let ns = NSColor(next).usingColorSpace(.sRGB) ?? .white
                        let codable = CodableColor(
                            red: Double(ns.redComponent),
                            green: Double(ns.greenComponent),
                            blue: Double(ns.blueComponent),
                            alpha: Double(ns.alphaComponent)
                        )
                        store.setParameter(nodeID: node.id, key: param.key, value: .color(codable), actionName: "Change \(param.label)")
                    }
                ))
                .labelsHidden()
            }

        case .anchorGrid:
            HStack(alignment: .top, spacing: 8) {
                Text("\(param.label):")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                    .padding(.top, 6)
                AnchorGridPicker(selection: val.stringValue ?? "center") { chosen in
                    store.setParameter(nodeID: node.id, key: param.key, value: .string(chosen), actionName: "Change Anchor")
                }
            }
        }
    }
}

private struct AnchorGridPicker: View {
    let selection: String
    let onSelect: (String) -> Void

    private let grid: [[String]] = [
        ["topLeft", "topCenter", "topRight"],
        ["middleLeft", "center", "middleRight"],
        ["bottomLeft", "bottomCenter", "bottomRight"]
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(grid, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection == item ? Color.accentColor : Color(nsColor: .controlColor))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
