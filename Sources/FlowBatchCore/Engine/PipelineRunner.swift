import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Metal

/// Progress & result summary returned when a batch workflow finishes.
public struct WorkflowRunSummary: Sendable {
    public let processedCount: Int
    public let writtenFiles: [URL]
    public let errors: [String]
    public let elapsedSeconds: Double
}

/// Preview render output delivered to the right-hand preview pane.
public struct PreviewRenderResult: @unchecked Sendable {
    public let processedImage: CIImage?
    public let originalImage: CIImage?
    public let info: AssetInspectorInfo?
    public let errorMessage: String?
}

/// Central execution actor managing dual Metal `CIContext`s, RAM-gated batch execution,
/// cooperative cancellation, memory pressure handling, and interactive node previewing.
public actor PipelineRunner {
    public let metalDevice: MTLDevice?
    public let previewContext: CIContext
    public let exportContext: CIContext

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureWarningActive = false
    private var memoryPressureCriticalAbort = false
    private var latestPreviewGeneration: UInt64 = 0

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        self.metalDevice = device

        if let device {
            self.previewContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: true,
                .name: "FlowBatch.Preview"
            ])
            self.exportContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .memoryTarget: 512,
                .name: "FlowBatch.Export"
            ])
        } else {
            self.previewContext = CIContext(options: [
                .cacheIntermediates: true,
                .name: "FlowBatch.Preview.CPU"
            ])
            self.exportContext = CIContext(options: [
                .cacheIntermediates: false,
                .memoryTarget: 512,
                .name: "FlowBatch.Export.CPU"
            ])
        }

        // Start memory pressure monitor asynchronously after init
        Task { await self.startMemoryPressureMonitor() }
    }

    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            let isCritical = source.data.contains(.critical)
            Task {
                await self?.handleMemoryPressure(isCritical: isCritical)
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    private func handleMemoryPressure(isCritical: Bool) {
        ThumbnailLoader.shared.evictAll()
        if isCritical {
            memoryPressureWarningActive = true
            memoryPressureCriticalAbort = true
        } else {
            memoryPressureWarningActive = true
        }
    }

    /// Computes safe concurrent full-resolution asset export cap based on physical RAM & pressure state.
    public func safeExportConcurrencyLimit(forEstimatedMaxMegapixels mp: Double) -> Int {
        if memoryPressureWarningActive || mp > 24.0 {
            return 1
        }
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000.0
        if ramGB < 20.0 { return 1 }      // 8–16 GB Macs: 1 full-res asset at a time
        if ramGB < 40.0 { return 2 }      // 32 GB Macs: 2
        return 4                          // 64 GB+ Macs: 4
    }

    // MARK: - Interactive Preview (Cached GPU Context)

    public func nextPreviewGeneration() -> UInt64 {
        latestPreviewGeneration &+= 1
        return latestPreviewGeneration
    }

    public func renderPreview(
        document: WorkflowDocumentModel,
        targetNodeID: UUID?,
        assetRef: DryRunAssetRef?,
        viewportMaxEdge: CGFloat = 1600,
        generationID: UInt64
    ) async -> PreviewRenderResult {
        guard generationID == latestPreviewGeneration else {
            return PreviewRenderResult(processedImage: nil, originalImage: nil, info: nil, errorMessage: nil)
        }

        let targetID = targetNodeID ?? document.topologicalOrder().last
        guard let targetID else {
            return PreviewRenderResult(processedImage: nil, originalImage: nil, info: nil, errorMessage: nil)
        }

        let order = document.subgraphOrder(upTo: targetID)
        let nodeMap = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let ctx = NodeExecutionContext(
            isPreview: true,
            previewContext: previewContext,
            exportContext: exportContext,
            rawScaleFactor: 0.25,
            subsampleFactor: viewportMaxEdge <= 1200 ? 2 : 1,
            promptService: NoopPromptService()
        )

        var originalAsset: PipelineAsset?
        if let url = assetRef?.url {
            originalAsset = try? PipelineAsset.load(
                from: url,
                sequenceIndex: 1,
                rawScaleFactor: ctx.rawScaleFactor,
                subsampleFactor: ctx.subsampleFactor
            )
        }

        var nodeStreams: [UUID: [PipelineAsset]] = [:]

        for nodeID in order {
            if generationID != latestPreviewGeneration || Task.isCancelled {
                return PreviewRenderResult(processedImage: nil, originalImage: nil, info: nil, errorMessage: nil)
            }
            guard let node = nodeMap[nodeID] else { continue }

            let incomingEdges = document.edges.filter { $0.targetNodeID == nodeID }
            let incoming: [PipelineAsset]
            if incomingEdges.isEmpty {
                incoming = []
            } else {
                incoming = incomingEdges.flatMap { edge in
                    nodeStreams[edge.sourceNodeID] ?? []
                }
            }

            if !node.isEnabled {
                nodeStreams[nodeID] = incoming
                continue
            }

            if node.definition?.isSource == true {
                if let orig = originalAsset, node.typeID == NodeTypeID.readFolder || node.typeID == NodeTypeID.readFiles {
                    // For single-asset interactive preview, only inject if this source contains the asset (or first source if synthetic)
                    let matchesFolder: Bool
                    if node.typeID == NodeTypeID.readFolder,
                       let folderPath = node.parameters["folderPath"]?.stringValue,
                       let assetURL = assetRef?.url {
                        matchesFolder = assetURL.path.hasPrefix(folderPath)
                    } else {
                        matchesFolder = true
                    }
                    nodeStreams[nodeID] = matchesFolder ? [orig.deepCopy()] : []
                } else if node.typeID == NodeTypeID.blankImage {
                    nodeStreams[nodeID] = DocumentGeneratorScriptExecutors.executeBlankImage(node: node)
                } else {
                    nodeStreams[nodeID] = (try? await ReadWriteExecutors.executeSource(node: node, context: ctx)) ?? []
                }
            } else if node.definition?.isBatchCollector == true {
                if node.typeID == NodeTypeID.sortOrder {
                    nodeStreams[nodeID] = MetadataSortExecutors.sortBatch(incoming, node: node)
                } else {
                    nodeStreams[nodeID] = (try? DocumentGeneratorScriptExecutors.executeBatchCollector(assets: incoming, node: node, context: ctx)) ?? incoming
                }
            } else {
                var out: [PipelineAsset] = []
                for item in incoming {
                    do {
                        let routed = try await executeSingleNode(asset: item, node: node, resolvedOutputFolder: nil, context: ctx)
                        out.append(contentsOf: routed.map(\.asset))
                    } catch {
                        return PreviewRenderResult(
                            processedImage: item.ciImage,
                            originalImage: originalAsset?.ciImage,
                            info: item.inspectorInfo(),
                            errorMessage: error.localizedDescription
                        )
                    }
                }
                nodeStreams[nodeID] = out
            }
        }

        let finalAsset = nodeStreams[targetID]?.first ?? originalAsset
        return PreviewRenderResult(
            processedImage: finalAsset?.ciImage,
            originalImage: originalAsset?.ciImage,
            info: finalAsset?.inspectorInfo(),
            errorMessage: nil
        )
    }

    // MARK: - Full-Resolution Batch Workflow Execution

    public func runWorkflow(
        document: WorkflowDocumentModel,
        promptService: any UserPromptService = NoopPromptService(),
        jsWorkerURL: URL? = nil,
        progressHandler: @escaping @Sendable (Double, String) -> Void = { _, _ in },
        logHandler: @escaping @Sendable (UUID?, String, ConsoleLogEntry.Level, String) -> Void = { _, _, _, _ in }
    ) async throws -> WorkflowRunSummary {
        let start = Date()
        memoryPressureCriticalAbort = false

        let order = document.topologicalOrder()
        let nodeMap = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })

        let ctx = NodeExecutionContext(
            isPreview: false,
            previewContext: previewContext,
            exportContext: exportContext,
            rawScaleFactor: 1.0,
            subsampleFactor: 1,
            promptService: promptService,
            jsWorkerURL: jsWorkerURL,
            logHandler: logHandler
        )

        // Pre-resolve interactive "Ask on Run" output folders on main actor before worker processing
        var resolvedOutputFolders: [UUID: URL] = [:]
        for nodeID in order {
            guard let node = nodeMap[nodeID], node.isEnabled, node.typeID == NodeTypeID.writeImages else { continue }
            if let folder = try await ReadWriteExecutors.resolveOutputDirectory(for: node, context: ctx) {
                resolvedOutputFolders[nodeID] = folder
            }
        }

        var portOutputs: [UUID: [Int: [PipelineAsset]]] = [:]
        var writtenURLs: [URL] = []
        var collectedErrors: [String] = []
        var processedAssets = 0

        let totalSteps = max(1, order.count)
        for (stepIdx, nodeID) in order.enumerated() {
            try Task.checkCancellation()
            if memoryPressureCriticalAbort {
                throw NodeExecutionError.memoryPressureAbort
            }
            guard let node = nodeMap[nodeID] else { continue }
            progressHandler(Double(stepIdx) / Double(totalSteps), "Running \(node.title)…")

            // Gather upstream assets per connected source port
            let incomingEdges = document.edges.filter { $0.targetNodeID == nodeID }
            let incoming: [PipelineAsset] = incomingEdges.flatMap { edge in
                (portOutputs[edge.sourceNodeID]?[edge.sourcePortIndex] ?? []).map { $0.deepCopy() }
            }

            if !node.isEnabled {
                portOutputs[nodeID] = [0: incoming]
                continue
            }

            // Sources
            if node.definition?.isSource == true {
                do {
                    let assets: [PipelineAsset]
                    switch node.typeID {
                    case NodeTypeID.blankImage:
                        assets = DocumentGeneratorScriptExecutors.executeBlankImage(node: node)
                    case NodeTypeID.screenshot:
                        assets = try await DocumentGeneratorScriptExecutors.executeScreenshot()
                    case NodeTypeID.readPhotosLibrary:
                        assets = try await DocumentGeneratorScriptExecutors.executeReadPhotosLibrary(node: node, context: ctx)
                    default:
                        assets = try await ReadWriteExecutors.executeSource(node: node, context: ctx)
                    }
                    portOutputs[nodeID] = [0: assets]
                    logHandler(node.id, node.title, .info, "Loaded \(assets.count) asset(s).")
                } catch {
                    let msg = error.localizedDescription
                    collectedErrors.append("\(node.title): \(msg)")
                    logHandler(node.id, node.title, .error, msg)
                    if node.errorPolicy == .haltWorkflow { throw error }
                    portOutputs[nodeID] = [0: []]
                }
                continue
            }

            // Batch Collectors
            if node.definition?.isBatchCollector == true {
                do {
                    let result: [PipelineAsset]
                    if node.typeID == NodeTypeID.sortOrder {
                        result = MetadataSortExecutors.sortBatch(incoming, node: node)
                    } else {
                        result = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: incoming, node: node, context: ctx)
                    }
                    portOutputs[nodeID] = [0: result]
                } catch {
                    let msg = error.localizedDescription
                    collectedErrors.append("\(node.title): \(msg)")
                    logHandler(node.id, node.title, .error, msg)
                    if node.errorPolicy == .haltWorkflow { throw error }
                    portOutputs[nodeID] = [0: node.errorPolicy == .passThroughOnFailure ? incoming : []]
                }
                continue
            }

            // Standard & Sink nodes: process inside per-asset autoreleasepool to bound RAM
            var byPort: [Int: [PipelineAsset]] = [:]
            for asset in incoming {
                try Task.checkCancellation()
                if memoryPressureCriticalAbort {
                    throw NodeExecutionError.memoryPressureAbort
                }

                do {
                    let routed: [RoutedAsset] = try await executeSingleNode(
                        asset: asset,
                        node: node,
                        resolvedOutputFolder: resolvedOutputFolders[nodeID],
                        context: ctx
                    )
                    for item in routed {
                        byPort[item.portIndex, default: []].append(item.asset)
                        if let written = item.asset.writtenOutputURL {
                            writtenURLs.append(written)
                            item.asset.writtenOutputURL = nil
                        }
                    }
                    processedAssets += 1
                } catch {
                    let msg = "\(asset.fileName): \(error.localizedDescription)"
                    collectedErrors.append("\(node.title) — \(msg)")
                    logHandler(node.id, node.title, .error, msg)
                    switch node.errorPolicy {
                    case .haltWorkflow:
                        throw error
                    case .skipAsset:
                        break
                    case .passThroughOnFailure:
                        byPort[0, default: []].append(asset)
                    }
                }
            }

            portOutputs[nodeID] = byPort

            if node.typeID == NodeTypeID.writeImages,
               node.parameters["openFolderWhenFinished"]?.boolValue == true,
               let folder = resolvedOutputFolders[nodeID],
               !writtenURLs.isEmpty {
                _ = await MainActor.run {
                    NSWorkspace.shared.open(folder)
                }
            }
        }

        progressHandler(1.0, "Finished (\(writtenURLs.count) exported).")
        return WorkflowRunSummary(
            processedCount: processedAssets,
            writtenFiles: writtenURLs,
            errors: collectedErrors,
            elapsedSeconds: Date().timeIntervalSince(start)
        )
    }

    private func executeSingleNode(
        asset: PipelineAsset,
        node: WorkflowNode,
        resolvedOutputFolder: URL?,
        context: NodeExecutionContext
    ) async throws -> [RoutedAsset] {
        switch node.typeID {
        case NodeTypeID.rawProcess:
            return try ReadWriteExecutors.executeRAWProcess(asset: asset, node: node, context: context)
        case NodeTypeID.multiScale:
            return ReadWriteExecutors.executeMultiScale(asset: asset, node: node)
        case NodeTypeID.writeImages:
            return try ReadWriteExecutors.executeWriteImages(
                asset: asset, node: node, resolvedOutputFolder: resolvedOutputFolder, context: context
            )
        case NodeTypeID.writeClipboard:
            return try await ReadWriteExecutors.executeWriteClipboard(asset: asset, context: context)
        case NodeTypeID.openInApp:
            return try ReadWriteExecutors.executeOpenInApp(asset: asset, node: node, context: context)
        case NodeTypeID.importToPhotos:
            return try await DocumentGeneratorScriptExecutors.executeImportToPhotos(asset: asset, node: node, context: context)
        default:
            switch node.definition?.category {
            case .blur, .sharpen, .colorAdjustment, .colorEffect:
                return try ColorFilterExecutors.execute(asset: asset, node: node, context: context)
            case .transform, .watermark:
                return try TransformWatermarkExecutors.execute(asset: asset, node: node, context: context)
            case .metadata, .sort:
                return try MetadataSortExecutors.execute(asset: asset, node: node, context: context)
            case .pdf, .misc, .script:
                return try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: asset, node: node, context: context)
            default:
                return [RoutedAsset(asset: asset)]
            }
        }
    }
}
