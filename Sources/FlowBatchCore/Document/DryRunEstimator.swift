import Foundation

/// Lightweight preflight descriptor of an asset discovered during dry-run estimation.
public struct DryRunAssetRef: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL?
    public let displayName: String

    public init(id: String, url: URL?, displayName: String) {
        self.id = id
        self.url = url
        self.displayName = displayName
    }
}

/// Complete preflight calculation for a workflow graph.
public struct DryRunSummary: Sendable {
    public let nodeCounts: [UUID: Int]
    public let nodeSubtitles: [UUID: String]
    public let nodeInputAssets: [UUID: [DryRunAssetRef]]
    public let readyToRead: Int
    public let readyToWrite: Int

    public init(
        nodeCounts: [UUID: Int] = [:],
        nodeSubtitles: [UUID: String] = [:],
        nodeInputAssets: [UUID: [DryRunAssetRef]] = [:],
        readyToRead: Int = 0,
        readyToWrite: Int = 0
    ) {
        self.nodeCounts = nodeCounts
        self.nodeSubtitles = nodeSubtitles
        self.nodeInputAssets = nodeInputAssets
        self.readyToRead = readyToRead
        self.readyToWrite = readyToWrite
    }

    public var statusText: String {
        let readNoun = readyToRead == 1 ? "asset" : "assets"
        return "\(readyToRead) \(readNoun) ready to read, \(readyToWrite) to write."
    }
}

/// Evaluates asset counts and dynamic subtitles across a workflow DAG without decoding image pixels.
public enum DryRunEstimator {
    public static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif",
        "webp", "bmp", "jp2", "j2k", "pdf", "dng", "cr2", "cr3",
        "nef", "arw", "orf", "raf", "rw2", "srw"
    ]

    public static func estimate(document: WorkflowDocumentModel) -> DryRunSummary {
        let nodeMap = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let order = document.topologicalOrder()

        var nodeOutCount: [UUID: Int] = [:]
        var nodeDisplayCount: [UUID: Int] = [:]
        var nodeSubtitles: [UUID: String] = [:]
        var nodeAssetsOut: [UUID: [DryRunAssetRef]] = [:]
        var nodeAssetsIn: [UUID: [DryRunAssetRef]] = [:]

        var totalRead = 0
        var totalWrite = 0

        for nodeID in order {
            guard let node = nodeMap[nodeID] else { continue }
            nodeSubtitles[nodeID] = subtitle(for: node)

            let incomingEdges = document.edges.filter { $0.targetNodeID == nodeID }
            let incomingCount: Int
            var mergedAssets: [DryRunAssetRef] = []

            if incomingEdges.isEmpty {
                incomingCount = 0
            } else {
                var sum = 0
                for edge in incomingEdges {
                    let sourceCount = nodeOutCount[edge.sourceNodeID] ?? 0
                    // For dual-output Rules node, port 0 = matched estimate, port 1 = remainder
                    if nodeMap[edge.sourceNodeID]?.typeID == NodeTypeID.rules, edge.sourcePortIndex == 1 {
                        sum += max(0, sourceCount / 2)
                    } else {
                        sum += sourceCount
                    }
                    mergedAssets.append(contentsOf: nodeAssetsOut[edge.sourceNodeID] ?? [])
                }
                incomingCount = sum
            }
            nodeAssetsIn[nodeID] = mergedAssets

            if !node.isEnabled {
                // Bypassed node passes input counts & assets downstream unchanged
                nodeOutCount[nodeID] = incomingCount
                nodeDisplayCount[nodeID] = incomingCount
                nodeAssetsOut[nodeID] = mergedAssets
                continue
            }

            let def = node.definition
            if def?.isSource == true {
                let assets = discoverSourceAssets(for: node)
                let count = assets.count
                nodeOutCount[nodeID] = count
                nodeDisplayCount[nodeID] = count
                nodeAssetsOut[nodeID] = assets
                nodeAssetsIn[nodeID] = assets
                totalRead += count
            } else if def?.isSink == true {
                nodeOutCount[nodeID] = 0
                nodeDisplayCount[nodeID] = incomingCount
                nodeAssetsOut[nodeID] = mergedAssets
                totalWrite += incomingCount
            } else {
                let multiplier: Int
                switch node.typeID {
                case NodeTypeID.multiScale:
                    let count = node.parameters["scales"]?.scalesValue?.count ?? 2
                    multiplier = max(1, count)
                    let outCount = incomingCount * multiplier
                    nodeOutCount[nodeID] = outCount
                    nodeDisplayCount[nodeID] = outCount
                    nodeAssetsOut[nodeID] = mergedAssets
                case NodeTypeID.duplicate:
                    let copies = max(1, node.parameters["copies"]?.intValue ?? 2)
                    let outCount = incomingCount * copies
                    nodeOutCount[nodeID] = outCount
                    nodeDisplayCount[nodeID] = outCount
                    nodeAssetsOut[nodeID] = mergedAssets
                case NodeTypeID.pdfMaker, NodeTypeID.imageGrid, NodeTypeID.animatedImage:
                    let outCount = incomingCount > 0 ? 1 : 0
                    nodeOutCount[nodeID] = outCount
                    nodeDisplayCount[nodeID] = incomingCount
                    nodeAssetsOut[nodeID] = mergedAssets
                default:
                    nodeOutCount[nodeID] = incomingCount
                    nodeDisplayCount[nodeID] = incomingCount
                    nodeAssetsOut[nodeID] = mergedAssets
                }
            }
        }

        return DryRunSummary(
            nodeCounts: nodeDisplayCount,
            nodeSubtitles: nodeSubtitles,
            nodeInputAssets: nodeAssetsIn,
            readyToRead: totalRead,
            readyToWrite: totalWrite
        )
    }

    public static func discoverSourceAssets(for node: WorkflowNode) -> [DryRunAssetRef] {
        switch node.typeID {
        case NodeTypeID.readFolder:
            guard let path = node.parameters["folderPath"]?.stringValue, !path.isEmpty else { return [] }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let recursive = node.parameters["includeSubfolders"]?.boolValue ?? false
            let extFilterRaw = node.parameters["filterExtensions"]?.stringValue ?? ""
            let customExts: Set<String> = Set(
                extFilterRaw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            let allowed = customExts.isEmpty ? supportedImageExtensions : customExts
            let urls = listImageURLs(in: url, recursive: recursive, allowedExtensions: allowed)
            return urls.map { DryRunAssetRef(id: $0.path, url: $0, displayName: $0.lastPathComponent) }

        case NodeTypeID.readFiles:
            let raw = node.parameters["filePaths"]?.stringValue ?? ""
            let paths = raw.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return paths.compactMap { path in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                return DryRunAssetRef(id: url.path, url: url, displayName: url.lastPathComponent)
            }

        case NodeTypeID.blankImage, NodeTypeID.screenshot, NodeTypeID.readClipboard:
            return [DryRunAssetRef(id: "generated-\(node.id.uuidString)", url: nil, displayName: node.title)]

        case NodeTypeID.promptForFiles:
            return []

        case NodeTypeID.readPhotosLibrary:
            let limit = node.parameters["limit"]?.intValue ?? 25
            return (0..<min(limit, 1)).map { idx in
                DryRunAssetRef(id: "photos-placeholder-\(idx)", url: nil, displayName: "Photos Library")
            }

        default:
            return []
        }
    }

    public static func listImageURLs(in folderURL: URL, recursive: Bool, allowedExtensions: Set<String> = supportedImageExtensions) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else { return [] }
        var urls: [URL] = []

        if recursive {
            if let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        urls.append(fileURL)
                    }
                }
            }
        } else if let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in contents where allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                urls.append(fileURL)
            }
        }

        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func subtitle(for node: WorkflowNode) -> String {
        switch node.typeID {
        case NodeTypeID.readFolder:
            let path = node.parameters["folderPath"]?.stringValue ?? ""
            return path.isEmpty ? "Choose Folder…" : URL(fileURLWithPath: path).lastPathComponent
        case NodeTypeID.readFiles:
            let count = discoverSourceAssets(for: node).count
            return count == 0 ? "No files selected" : "\(count) selected"
        case NodeTypeID.writeImages:
            if node.parameters["askForOutputFolder"]?.boolValue == true {
                return "Ask when run"
            }
            let path = node.parameters["folderPath"]?.stringValue ?? ""
            return path.isEmpty ? "Choose Folder…" : URL(fileURLWithPath: path).lastPathComponent
        case NodeTypeID.textWatermark:
            let txt = node.parameters["text"]?.stringValue ?? ""
            return txt.isEmpty ? "Text Watermark" : txt
        case NodeTypeID.scale:
            let mode = node.parameters["mode"]?.stringValue ?? "Fixed Width"
            switch mode {
            case "Fixed Width":
                return "Fixed \(node.parameters["width"]?.intValue ?? 800) width"
            case "Fixed Height":
                return "Fixed \(node.parameters["height"]?.intValue ?? 600) height"
            case "Percentage":
                return "\(Int(node.parameters["percent"]?.doubleValue ?? 50))%"
            case "Fit Inside":
                return "Fit \(node.parameters["width"]?.intValue ?? 800)×\(node.parameters["height"]?.intValue ?? 600)"
            default:
                return "\(node.parameters["width"]?.intValue ?? 800)×\(node.parameters["height"]?.intValue ?? 600)"
            }
        case NodeTypeID.gaussianBlur, NodeTypeID.boxBlur:
            return String(format: "Radius %.1f px", node.parameters["radius"]?.doubleValue ?? 10)
        case NodeTypeID.photoEffect:
            return node.parameters["style"]?.stringValue ?? "Noir"
        case NodeTypeID.exposure:
            return String(format: "%+.2f EV", node.parameters["ev"]?.doubleValue ?? 0)
        case NodeTypeID.rotate:
            return String(format: "%.0f°", node.parameters["degrees"]?.doubleValue ?? 90)
        case NodeTypeID.flip:
            return node.parameters["direction"]?.stringValue ?? "Horizontal"
        case NodeTypeID.rules:
            let count = node.parameters["rules"]?.rulesValue?.count ?? 0
            return count == 1 ? "1 Rule" : "\(count) Rules"
        case NodeTypeID.pdfMaker:
            return (node.parameters["fileName"]?.stringValue ?? "Combined") + ".pdf"
        case NodeTypeID.multiScale:
            let scales = node.parameters["scales"]?.scalesValue?.map(\.label).joined(separator: ", ") ?? "1x, 2x"
            return scales
        default:
            return node.definition?.summary ?? ""
        }
    }
}
