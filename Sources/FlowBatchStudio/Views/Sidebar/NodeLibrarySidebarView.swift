import FlowBatchCore
import SwiftUI
import UniformTypeIdentifiers

/// Left sidebar listing all 15 node categories with search filtering, drag-to-canvas (`UTType.flowbatchNodeTemplate`),
/// and double-click quick insertion.
struct NodeLibrarySidebarView: View {
    @Bindable var store: WorkflowStore
    @State private var searchQuery: String = ""
    @State private var expandedCategories: Set<NodeCategory> = []

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Category Disclosure List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(NodeCategory.allCases) { category in
                        let items = NodeCatalog.nodes(in: category, matching: searchQuery)
                        if !items.isEmpty || searchQuery.isEmpty {
                            CategoryRowView(
                                category: category,
                                items: items,
                                isExpanded: searchQuery.isEmpty ? expandedCategories.contains(category) : true,
                                onToggle: {
                                    if expandedCategories.contains(category) {
                                        expandedCategories.remove(category)
                                    } else {
                                        expandedCategories.insert(category)
                                    }
                                },
                                onDoubleClickNode: { def in
                                    insertNodeAtSmartPosition(def)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func insertNodeAtSmartPosition(_ def: NodeDefinition) {
        let anchorID = store.primarySelectedNodeID
        let anchorPos = store.primarySelectedNode?.position ?? GraphPoint(x: 200, y: 180)
        let targetPos = GraphPoint(x: anchorPos.x + 180, y: anchorPos.y)
        let canAutoWire = def.inputPortCount > 0 ? anchorID : nil
        store.addNode(typeID: def.typeID, at: targetPos, autoConnectFrom: canAutoWire)
    }
}

private struct CategoryRowView: View {
    let category: NodeCategory
    let items: [NodeDefinition]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDoubleClickNode: (NodeDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(category.localizedName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(items) { def in
                    NodeTemplateRowView(definition: def)
                        .onTapGesture(count: 2) {
                            onDoubleClickNode(def)
                        }
                        .onDrag {
                            if let data = try? JSONEncoder().encode(NodeDragPayload(typeID: def.typeID)) {
                                return NSItemProvider(
                                    item: data as NSData,
                                    typeIdentifier: UTType.flowbatchNodeTemplate.identifier
                                )
                            }
                            return NSItemProvider(object: "flowbatch-node:\(def.typeID)" as NSString)
                        }
                }
            }
        }
    }
}

private struct NodeTemplateRowView: View {
    let definition: NodeDefinition
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: definition.category.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(definition.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(definition.summary)
    }
}
