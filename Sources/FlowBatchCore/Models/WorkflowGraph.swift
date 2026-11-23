import CoreGraphics
import Foundation

/// Serializable payload transferred when dragging a node template from the sidebar to the canvas.
public struct NodeDragPayload: Codable, Sendable {
    public let typeID: String

    public init(typeID: String) {
        self.typeID = typeID
    }
}

/// Codable 2D point wrapper that stays clean across platforms.
public struct GraphPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ cgPoint: CGPoint) {
        self.x = Double(cgPoint.x)
        self.y = Double(cgPoint.y)
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// A single node instance placed on the workflow canvas.
public struct WorkflowNode: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var typeID: String
    public var title: String
    public var position: GraphPoint
    public var isEnabled: Bool
    public var errorPolicy: NodeErrorPolicy
    public var parameters: [String: NodeParamValue]

    public init(
        id: UUID = UUID(),
        typeID: String,
        title: String? = nil,
        position: GraphPoint,
        isEnabled: Bool = true,
        errorPolicy: NodeErrorPolicy = .skipAsset,
        parameters: [String: NodeParamValue]? = nil
    ) {
        let def = NodeCatalog.definition(for: typeID)
        self.id = id
        self.typeID = typeID
        self.title = title ?? def?.title ?? typeID
        self.position = position
        self.isEnabled = isEnabled
        self.errorPolicy = errorPolicy
        var merged = def?.defaultParameters ?? [:]
        if let parameters {
            for (k, v) in parameters {
                merged[k] = v
            }
        }
        self.parameters = merged
    }

    public var definition: NodeDefinition? {
        NodeCatalog.definition(for: typeID)
    }
}

/// Directed edge connecting an output port of one node to an input port of another node.
public struct WorkflowEdge: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var sourcePortIndex: Int
    public var targetNodeID: UUID
    public var targetPortIndex: Int

    public init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        sourcePortIndex: Int = 0,
        targetNodeID: UUID,
        targetPortIndex: Int = 0
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.sourcePortIndex = sourcePortIndex
        self.targetNodeID = targetNodeID
        self.targetPortIndex = targetPortIndex
    }
}

/// Complete JSON-serializable `.flowbatch` workflow document.
public struct WorkflowDocumentModel: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var documentTitle: String
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    public var viewportOffset: GraphPoint
    public var viewportZoom: Double

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        documentTitle: String = "Untitled.flowbatch",
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        viewportOffset: GraphPoint = GraphPoint(x: 0, y: 0),
        viewportZoom: Double = 1.0
    ) {
        self.schemaVersion = schemaVersion
        self.documentTitle = documentTitle
        self.nodes = nodes
        self.edges = edges
        self.viewportOffset = viewportOffset
        self.viewportZoom = viewportZoom
    }

    /// Returns node IDs in deterministic topological order (sources first, sinks last).
    public func topologicalOrder() -> [UUID] {
        var inDegree: [UUID: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var outgoing: [UUID: [UUID]] = [:]

        for edge in edges {
            guard inDegree[edge.sourceNodeID] != nil, inDegree[edge.targetNodeID] != nil else { continue }
            outgoing[edge.sourceNodeID, default: []].append(edge.targetNodeID)
            inDegree[edge.targetNodeID, default: 0] += 1
        }

        // Tie-break deterministically by visual (x, y) coordinates
        let positions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        func visualBefore(_ a: UUID, _ b: UUID) -> Bool {
            let pa = positions[a] ?? GraphPoint(x: 0, y: 0)
            let pb = positions[b] ?? GraphPoint(x: 0, y: 0)
            if abs(pa.x - pb.x) > 1 { return pa.x < pb.x }
            if abs(pa.y - pb.y) > 1 { return pa.y < pb.y }
            return a.uuidString < b.uuidString
        }

        var queue = inDegree.filter { $0.value == 0 }.map { $0.key }.sorted(by: visualBefore)
        var result: [UUID] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)
            for next in outgoing[current] ?? [] {
                inDegree[next, default: 0] -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                    queue.sort(by: visualBefore)
                }
            }
        }
        return result
    }

    /// Checks whether adding edge `source -> target` would introduce a cycle or duplicate edge.
    public func canConnect(from sourceID: UUID, sourcePort: Int = 0, to targetID: UUID, targetPort: Int = 0) -> Bool {
        guard sourceID != targetID else { return false }
        guard let sourceNode = nodes.first(where: { $0.id == sourceID }),
              let targetNode = nodes.first(where: { $0.id == targetID }) else { return false }

        let maxOut = sourceNode.definition?.outputPortCount ?? 1
        let maxIn = targetNode.definition?.inputPortCount ?? 1
        guard sourcePort >= 0 && sourcePort < maxOut && targetPort >= 0 && targetPort < maxIn else {
            return false
        }

        let alreadyExists = edges.contains {
            $0.sourceNodeID == sourceID &&
            $0.sourcePortIndex == sourcePort &&
            $0.targetNodeID == targetID &&
            $0.targetPortIndex == targetPort
        }
        if alreadyExists { return false }

        // DFS from target to see if source is reachable (which would close a cycle)
        var visited: Set<UUID> = []
        var stack: [UUID] = [targetID]
        while let current = stack.popLast() {
            if current == sourceID { return false }
            if visited.insert(current).inserted {
                let nextIDs = edges.filter { $0.sourceNodeID == current }.map(\.targetNodeID)
                stack.append(contentsOf: nextIDs)
            }
        }
        return true
    }

    /// Returns topological order restricted to ancestors of `targetNodeID` (plus `targetNodeID` itself).
    public func subgraphOrder(upTo targetNodeID: UUID) -> [UUID] {
        var needed: Set<UUID> = [targetNodeID]
        var stack: [UUID] = [targetNodeID]
        while let current = stack.popLast() {
            for edge in edges where edge.targetNodeID == current {
                if needed.insert(edge.sourceNodeID).inserted {
                    stack.append(edge.sourceNodeID)
                }
            }
        }
        return topologicalOrder().filter { needed.contains($0) }
    }

    /// Creates the default starter workflow (`Watermark Images.flowbatch`).
    public static func makeStarterDocument(demoAssetsRoot: URL?) -> WorkflowDocumentModel {
        let aug9Path = demoAssetsRoot?.appendingPathComponent("Aug 9 Shots").path ?? ""
        let aug11Path = demoAssetsRoot?.appendingPathComponent("Aug 11 Shots").path ?? ""
        let defaultOutput = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Thumbnails").path ?? NSTemporaryDirectory() + "Thumbnails"

        let read1 = WorkflowNode(
            typeID: NodeTypeID.readFolder,
            position: GraphPoint(x: 90, y: 90),
            parameters: ["folderPath": .string(aug9Path)]
        )
        let read2 = WorkflowNode(
            typeID: NodeTypeID.readFolder,
            position: GraphPoint(x: 90, y: 270),
            parameters: ["folderPath": .string(aug11Path)]
        )
        let watermark = WorkflowNode(
            typeID: NodeTypeID.textWatermark,
            position: GraphPoint(x: 280, y: 180),
            parameters: [
                "text": .string("@ FlowBatch Sample"),
                "fontSize": .double(28),
                "opacity": .double(0.75),
                "anchor": .string("bottomRight")
            ]
        )
        let scale = WorkflowNode(
            typeID: NodeTypeID.scale,
            position: GraphPoint(x: 470, y: 90),
            parameters: [
                "mode": .string("Fixed Width"),
                "width": .int(800)
            ]
        )
        let write = WorkflowNode(
            typeID: NodeTypeID.writeImages,
            position: GraphPoint(x: 655, y: 90),
            parameters: [
                "folderPath": .string(defaultOutput),
                "openFolderWhenFinished": .bool(true),
                "overwriteExisting": .bool(true),
                "fileNamePattern": .string("[File Name]"),
                "format": .string("PNG"),
                "removeAlphaIfOpaque": .bool(true),
                "makeIndexedPNG": .bool(true),
                "indexedColors": .int(256),
                "indexedSpeed": .int(1),
                "indexedDither": .bool(false)
            ]
        )

        let edges = [
            WorkflowEdge(sourceNodeID: read1.id, targetNodeID: watermark.id),
            WorkflowEdge(sourceNodeID: read2.id, targetNodeID: watermark.id),
            WorkflowEdge(sourceNodeID: watermark.id, targetNodeID: scale.id),
            WorkflowEdge(sourceNodeID: scale.id, targetNodeID: write.id)
        ]

        return WorkflowDocumentModel(
            documentTitle: "Watermark Images.flowbatch",
            nodes: [read1, read2, watermark, scale, write],
            edges: edges
        )
    }

    /// Locates bundled or workspace `DemoAssets` if available on disk.
    public static func locateDemoAssetsDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("DemoAssets", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Resources/DemoAssets", isDirectory: true))
        candidates.append(cwd.appendingPathComponent("../Resources/DemoAssets", isDirectory: true))

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent("Aug 9 Shots").path) {
                return candidate
            }
        }
        return nil
    }
}
