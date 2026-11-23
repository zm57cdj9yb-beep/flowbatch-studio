import AppKit
import FlowBatchCore
import SwiftUI

/// Token pill editor displaying blue clickable metadata tokens alongside editable text and a `⊖ ⌄` menu.
struct TokenPatternFieldView: View {
    let pattern: String
    let onChange: (String) -> Void

    @State private var isEditingRaw = false
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if isEditingRaw {
                    TextField("Pattern", text: $draft, onCommit: {
                        onChange(draft)
                        isEditingRaw = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(5)
                    .frame(minHeight: 42, alignment: .topLeading)
                } else {
                    FlowLayoutChips(segments: parseSegments(pattern))
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                        .padding(5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = pattern
                            isEditingRaw = true
                        }
                }

                HStack(spacing: 4) {
                    Button {
                        onChange("")
                        draft = ""
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear Pattern"))

                    Menu {
                        ForEach(TokenExpander.availableTokens, id: \.token) { item in
                            Button(item.label) {
                                let sep = pattern.isEmpty ? "" : (pattern.hasSuffix(" ") || pattern.hasSuffix("_") ? "" : " ")
                                let updated = pattern + sep + item.token
                                onChange(updated)
                                draft = updated
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 14)
                }
                .padding(.top, 5)
                .padding(.trailing, 5)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private enum Segment: Identifiable {
        case token(id: Int, label: String)
        case text(id: Int, value: String)

        var id: Int {
            switch self {
            case .token(let id, _), .text(let id, _): return id
            }
        }
    }

    private func parseSegments(_ input: String) -> [Segment] {
        var result: [Segment] = []
        var idx = 0
        var remaining = input[...]
        while let open = remaining.firstIndex(of: "["),
              let close = remaining[open...].firstIndex(of: "]") {
            let prefix = String(remaining[..<open])
            if !prefix.isEmpty {
                result.append(.text(id: idx, value: prefix))
                idx += 1
            }
            let inner = String(remaining[remaining.index(after: open)..<close])
            result.append(.token(id: idx, label: inner))
            idx += 1
            remaining = remaining[remaining.index(after: close)...]
        }
        let tail = String(remaining)
        if !tail.isEmpty {
            result.append(.text(id: idx, value: tail))
        }
        return result
    }

    private struct FlowLayoutChips: View {
        let segments: [Segment]

        var body: some View {
            HStack(spacing: 4) {
                ForEach(segments) { seg in
                    switch seg {
                    case .token(_, let label):
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
                    case .text(_, let value):
                        Text(value)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

/// Complete inspector popover for `Write Images`, matching the layout, options,
/// token builder, format switcher, and Indexed PNG controls cleanly.
struct WriteImagesInspectorView: View {
    @Bindable var store: WorkflowStore
    let node: WorkflowNode

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Folder row
            HStack(alignment: .center, spacing: 8) {
                Text("Folder:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)

                Menu {
                    Button(String(localized: "Choose Folder…")) {
                        pickOutputFolder()
                    }
                    if let currentPath = currentFolderPath, !currentPath.isEmpty {
                        Button(String(localized: "Reveal in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(folderDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .disabled(boolParam("writeBackToOriginal") || boolParam("askForOutputFolder"))
            }

            // Primary checkboxes
            VStack(alignment: .leading, spacing: 5) {
                checkbox("Open folder when export finishes", key: "openFolderWhenFinished")
                checkbox("Overwrite existing images", key: "overwriteExisting")
            }
            .padding(.leading, 80)

            // Advanced section
            HStack(alignment: .top, spacing: 8) {
                Text("Advanced:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)

                VStack(alignment: .leading, spacing: 5) {
                    checkbox("Write back to original images", key: "writeBackToOriginal")
                    checkbox("Ask for output folder when run", key: "askForOutputFolder")
                    checkbox("Read back encoded image", key: "readBackEncoded")
                    checkbox("Keep original and modified dates", key: "keepOriginalDates")
                }
            }

            // Tokenized File Name
            HStack(alignment: .top, spacing: 8) {
                Text("File name:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                    .padding(.top, 4)

                TokenPatternFieldView(pattern: stringParam("fileNamePattern", default: "[File Name]")) { updated in
                    store.setParameter(nodeID: node.id, key: "fileNamePattern", value: .string(updated), actionName: "Edit File Name Pattern")
                }
            }

            // Convert to format dropdown
            HStack(spacing: 8) {
                Text("Convert to:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)

                Picker("", selection: formatBinding) {
                    ForEach(NodeCatalog.outputFormats, id: \.self) { fmt in
                        Text(fmt).tag(fmt)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            let selectedFormat = stringParam("format", default: "PNG")
            if selectedFormat == "PNG" {
                VStack(alignment: .leading, spacing: 5) {
                    checkbox("Remove alpha channel if opaque", key: "removeAlphaIfOpaque")
                    checkbox("Crush (slow)", key: "crushPNG")
                    checkbox("Brute force crush (very slow)", key: "bruteForceCrushPNG")
                        .disabled(!boolParam("crushPNG") && !boolParam("makeIndexedPNG"))
                    checkbox("Remove color profile", key: "removeColorProfile")
                }
                .padding(.leading, 80)

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    checkbox("Make indexed PNG", key: "makeIndexedPNG")
                        .padding(.leading, 80)

                    let indexedOn = boolParam("makeIndexedPNG")
                    HStack(spacing: 8) {
                        Text("Colors:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)

                        CoalescedIntSlider(
                            store: store,
                            nodeID: node.id,
                            key: "indexedColors",
                            range: 2...256,
                            defaultValue: 256,
                            actionName: "Adjust Indexed Colors"
                        )
                        Text("\(intParam("indexedColors", default: 256))")
                            .font(.system(size: 11.5))
                            .frame(width: 30, alignment: .leading)
                    }
                    .disabled(!indexedOn)
                    .opacity(indexedOn ? 1 : 0.45)

                    HStack(spacing: 8) {
                        Text("Speed:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)

                        CoalescedIntSlider(
                            store: store,
                            nodeID: node.id,
                            key: "indexedSpeed",
                            range: 1...10,
                            defaultValue: 1,
                            actionName: "Adjust Indexed Speed"
                        )
                        Text(speedLabel(intParam("indexedSpeed", default: 1)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .disabled(!indexedOn)
                    .opacity(indexedOn ? 1 : 0.45)

                    checkbox("Dither", key: "indexedDither")
                        .padding(.leading, 108)
                        .disabled(!indexedOn)
                        .opacity(indexedOn ? 1 : 0.45)
                }
            } else if ["JPEG", "HEIC", "AVIF", "JPEG 2000"].contains(selectedFormat) {
                HStack(spacing: 8) {
                    Text("Quality:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)

                    CoalescedDoubleSlider(
                        store: store,
                        nodeID: node.id,
                        key: "quality",
                        range: 0.1...1.0,
                        defaultValue: 0.88,
                        actionName: "Adjust Quality"
                    )
                    Text("\(Int((doubleParam("quality", default: 0.88) * 100).rounded()))%")
                        .font(.system(size: 11.5))
                        .frame(width: 38, alignment: .leading)
                }
                checkbox("Remove color profile", key: "removeColorProfile")
                    .padding(.leading, 80)
            }
        }
    }

    private var currentFolderPath: String? {
        node.parameters["folderPath"]?.stringValue
    }

    private var folderDisplayName: String {
        guard let p = currentFolderPath, !p.isEmpty else { return "Choose Folder…" }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            store.setParameter(nodeID: node.id, key: "folderPath", value: .string(url.path), actionName: "Choose Output Folder")
        }
    }

    private var formatBinding: Binding<String> {
        Binding(
            get: { stringParam("format", default: "PNG") },
            set: { store.setParameter(nodeID: node.id, key: "format", value: .string($0), actionName: "Change Output Format") }
        )
    }

    private func boolParam(_ key: String) -> Bool {
        node.parameters[key]?.boolValue ?? false
    }

    private func intParam(_ key: String, default def: Int) -> Int {
        node.parameters[key]?.intValue ?? def
    }

    private func doubleParam(_ key: String, default def: Double) -> Double {
        node.parameters[key]?.doubleValue ?? def
    }

    private func stringParam(_ key: String, default def: String) -> String {
        node.parameters[key]?.stringValue ?? def
    }

    private func checkbox(_ title: String, key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { boolParam(key) },
            set: { store.setParameter(nodeID: node.id, key: key, value: .bool($0), actionName: title) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private func speedLabel(_ speed: Int) -> String {
        if speed <= 2 { return "Slowest, best quality (\(speed))" }
        if speed >= 8 { return "Fastest (\(speed))" }
        return "Balanced (\(speed))"
    }
}
