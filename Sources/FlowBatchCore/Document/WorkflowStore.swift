import Foundation
import Observation

/// Structured console entry emitted during workflow execution.
public struct ConsoleLogEntry: Identifiable, Sendable {
    public enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let nodeID: UUID?
    public let nodeTitle: String
    public let level: Level
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        nodeID: UUID? = nil,
        nodeTitle: String,
        level: Level,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.nodeID = nodeID
        self.nodeTitle = nodeTitle
        self.level = level
        self.message = message
    }
}

/// Primary `@Observable` document state controller managing graph mutations, coalesced undo/redo,
/// JSON `.flowbatch` persistence, selection state, and dry-run statistics.
@MainActor
@Observable
public final class WorkflowStore {
    public var document: WorkflowDocumentModel
    public var fileURL: URL?
    public var hasUnsavedChanges: Bool = false

    public var selectedNodeIDs: Set<UUID> = []
    public var selectedEdgeID: UUID?
    public var selectedAssetIndex: Int = 0
    public var inspectorVisibleNodeID: UUID?

    public var dryRun: DryRunSummary = DryRunSummary()
    public var isRunning: Bool = false
    public var runProgress: Double = 0.0
    public var runStatusDetail: String = ""
    public var nodeErrors: [UUID: String] = [:]
    public var consoleEntries: [ConsoleLogEntry] = []

    public let undoManager: UndoManager

    private var continuousBaseline: WorkflowDocumentModel?

    public init(
        document: WorkflowDocumentModel? = nil,
        undoManager: UndoManager = UndoManager()
    ) {
        self.undoManager = undoManager
        let initial = document ?? WorkflowDocumentModel.makeStarterDocument(
            demoAssetsRoot: WorkflowDocumentModel.locateDemoAssetsDirectory()
        )
        self.document = initial
        if let writeNode = initial.nodes.first(where: { $0.typeID == NodeTypeID.writeImages }) ?? initial.nodes.last {
            self.selectedNodeIDs = [writeNode.id]
            self.inspectorVisibleNodeID = writeNode.id
        }
        refreshDryRun()
    }

    public var primarySelectedNodeID: UUID? {
        if selectedNodeIDs.count == 1 { return selectedNodeIDs.first }
        return inspectorVisibleNodeID ?? selectedNodeIDs.first
    }

    public var primarySelectedNode: WorkflowNode? {
        guard let id = primarySelectedNodeID else { return nil }
        return document.nodes.first(where: { $0.id == id })
    }

    /// Assets to show in the right-hand thumbnail grid based on the selected node (or all read assets).
    public var activePreviewAssets: [DryRunAssetRef] {
        if let selectedID = primarySelectedNodeID,
           let nodeAssets = dryRun.nodeInputAssets[selectedID],
           !nodeAssets.isEmpty {
            return nodeAssets
        }
        // Fallback: aggregate all source nodes
        return document.nodes.flatMap { dryRun.nodeInputAssets[$0.id] ?? [] }
    }

    public func refreshDryRun() {
        dryRun = DryRunEstimator.estimate(document: document)
        let maxIdx = max(0, activePreviewAssets.count - 1)
        if selectedAssetIndex > maxIdx {
            selectedAssetIndex = 0
        }
    }

    // MARK: - Coalesced Continuous Editing (Node Drag / Slider Scrub)

    public func beginContinuousEdit() {
        if continuousBaseline == nil {
            continuousBaseline = document
        }
    }

    public func commitContinuousEdit(actionName: String) {
        guard let before = continuousBaseline else { return }
        continuousBaseline = nil
        guard before != document else { return }
        let after = document
        registerUndo(from: before, to: after, actionName: actionName)
        refreshDryRun()
    }

    public func updateNodePositionsTransient(_ updates: [UUID: GraphPoint]) {
        for index in document.nodes.indices {
            if let nextPos = updates[document.nodes[index].id] {
                document.nodes[index].position = nextPos
            }
        }
        hasUnsavedChanges = true
    }

    public func setParameterTransient(nodeID: UUID, key: String, value: NodeParamValue) {
        guard let idx = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        document.nodes[idx].parameters[key] = value
        hasUnsavedChanges = true
        refreshDryRun()
    }

    // MARK: - Discrete Undo-Registered Graph Edits

    @discardableResult
    public func addNode(typeID: String, at position: GraphPoint, autoConnectFrom sourceID: UUID? = nil) -> WorkflowNode {
        let before = document
        let node = WorkflowNode(typeID: typeID, position: position)
        document.nodes.append(node)
        if let sourceID, document.canConnect(from: sourceID, sourcePort: 0, to: node.id, targetPort: 0) {
            document.edges.append(WorkflowEdge(sourceNodeID: sourceID, targetNodeID: node.id))
        }
        selectedNodeIDs = [node.id]
        selectedEdgeID = nil
        inspectorVisibleNodeID = node.id
        registerUndo(from: before, to: document, actionName: String(localized: "Add \(node.title)"))
        refreshDryRun()
        return node
    }

    public func removeNodes(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = document
        document.nodes.removeAll { ids.contains($0.id) }
        document.edges.removeAll { ids.contains($0.sourceNodeID) || ids.contains($0.targetNodeID) }
        selectedNodeIDs.subtract(ids)
        if let insp = inspectorVisibleNodeID, ids.contains(insp) {
            inspectorVisibleNodeID = nil
        }
        registerUndo(from: before, to: document, actionName: String(localized: "Delete Node"))
        refreshDryRun()
    }

    @discardableResult
    public func connect(sourceID: UUID, sourcePort: Int = 0, targetID: UUID, targetPort: Int = 0) -> Bool {
        guard document.canConnect(from: sourceID, sourcePort: sourcePort, to: targetID, targetPort: targetPort) else {
            return false
        }
        let before = document
        document.edges.append(
            WorkflowEdge(
                sourceNodeID: sourceID,
                sourcePortIndex: sourcePort,
                targetNodeID: targetID,
                targetPortIndex: targetPort
            )
        )
        registerUndo(from: before, to: document, actionName: String(localized: "Connect Nodes"))
        refreshDryRun()
        return true
    }

    public func removeEdge(id: UUID) {
        let before = document
        document.edges.removeAll { $0.id == id }
        if selectedEdgeID == id { selectedEdgeID = nil }
        registerUndo(from: before, to: document, actionName: String(localized: "Disconnect Nodes"))
        refreshDryRun()
    }

    public func setNodeEnabled(id: UUID, enabled: Bool) {
        guard let idx = document.nodes.firstIndex(where: { $0.id == id }),
              document.nodes[idx].isEnabled != enabled else { return }
        let before = document
        document.nodes[idx].isEnabled = enabled
        registerUndo(from: before, to: document, actionName: enabled ? String(localized: "Enable Node") : String(localized: "Disable Node"))
        refreshDryRun()
    }

    public func setParameter(nodeID: UUID, key: String, value: NodeParamValue, actionName: String? = nil) {
        guard let idx = document.nodes.firstIndex(where: { $0.id == nodeID }),
              document.nodes[idx].parameters[key] != value else { return }
        let before = document
        document.nodes[idx].parameters[key] = value
        registerUndo(from: before, to: document, actionName: actionName ?? String(localized: "Change Setting"))
        refreshDryRun()
    }

    public func setErrorPolicy(nodeID: UUID, policy: NodeErrorPolicy) {
        guard let idx = document.nodes.firstIndex(where: { $0.id == nodeID }),
              document.nodes[idx].errorPolicy != policy else { return }
        let before = document
        document.nodes[idx].errorPolicy = policy
        registerUndo(from: before, to: document, actionName: String(localized: "Change Error Policy"))
    }

    public func selectNode(_ id: UUID?, toggle: Bool = false, showInspector: Bool = true) {
        selectedEdgeID = nil
        guard let id else {
            selectedNodeIDs.removeAll()
            inspectorVisibleNodeID = nil
            return
        }
        if toggle {
            if selectedNodeIDs.contains(id) {
                selectedNodeIDs.remove(id)
            } else {
                selectedNodeIDs.insert(id)
            }
            inspectorVisibleNodeID = selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil
        } else {
            selectedNodeIDs = [id]
            if showInspector {
                inspectorVisibleNodeID = id
            }
        }
    }

    public func nudgeSelectedNodes(dx: Double, dy: Double) {
        guard !selectedNodeIDs.isEmpty else { return }
        let before = document
        for index in document.nodes.indices where selectedNodeIDs.contains(document.nodes[index].id) {
            document.nodes[index].position.x += dx
            document.nodes[index].position.y += dy
        }
        registerUndo(from: before, to: document, actionName: String(localized: "Move Node"))
    }

    public func appendLog(_ entry: ConsoleLogEntry) {
        consoleEntries.append(entry)
        if entry.level == .error, let nodeID = entry.nodeID {
            nodeErrors[nodeID] = entry.message
        }
    }

    public func clearRunLogs() {
        consoleEntries.removeAll()
        nodeErrors.removeAll()
    }

    // MARK: - Persistence (.flowbatch JSON)

    public func encodedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public func save(to url: URL) throws {
        var docCopy = document
        docCopy.documentTitle = url.lastPathComponent
        document = docCopy
        let data = try encodedJSONData()
        try data.write(to: url, options: .atomic)
        fileURL = url
        hasUnsavedChanges = false
    }

    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try Self.decodeDocument(from: data)
        undoManager.removeAllActions()
        document = decoded
        fileURL = url
        hasUnsavedChanges = false
        selectedNodeIDs = decoded.nodes.first.map { [$0.id] } ?? []
        inspectorVisibleNodeID = selectedNodeIDs.first
        clearRunLogs()
        refreshDryRun()
    }

    public static func decodeDocument(from data: Data) throws -> WorkflowDocumentModel {
        try JSONDecoder().decode(WorkflowDocumentModel.self, from: data)
    }

    // MARK: - Undo Registration

    private func registerUndo(from before: WorkflowDocumentModel, to after: WorkflowDocumentModel, actionName: String) {
        hasUnsavedChanges = true
        undoManager.registerUndo(withTarget: self) { target in
            target.applySnapshot(before, inverseTarget: after, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func applySnapshot(_ snapshot: WorkflowDocumentModel, inverseTarget: WorkflowDocumentModel, actionName: String) {
        document = snapshot
        hasUnsavedChanges = true
        let existingIDs = Set(document.nodes.map(\.id))
        selectedNodeIDs = selectedNodeIDs.intersection(existingIDs)
        if let insp = inspectorVisibleNodeID, !existingIDs.contains(insp) {
            inspectorVisibleNodeID = selectedNodeIDs.first
        }
        undoManager.registerUndo(withTarget: self) { target in
            target.applySnapshot(inverseTarget, inverseTarget: snapshot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        refreshDryRun()
    }
}
