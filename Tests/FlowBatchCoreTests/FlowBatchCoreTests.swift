import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FlowBatchCore

final class FlowBatchCoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeGradientCIImage(width: Int, height: Int, includeAlpha: Bool = false) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = UInt8((x * 255) / max(1, width - 1))
                rgba[i + 1] = UInt8((y * 255) / max(1, height - 1))
                rgba[i + 2] = UInt8(((x + y) * 127) / max(1, width + height - 2))
                rgba[i + 3] = includeAlpha && x < width / 4 ? 128 : 255
            }
        }
        return CIImage(
            bitmapData: Data(rgba),
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: cs
        )
    }

    private func demoAssetsDirectory() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("Resources/DemoAssets", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Aug 9 Shots").path) {
            return candidate
        }
        // Synthesize 16 + 14 lightweight JPEGs on fresh clones where DemoAssets haven't been generated yet
        let synthRoot = tempDir.appendingPathComponent("SynthDemoAssets", isDirectory: true)
        let aug9 = synthRoot.appendingPathComponent("Aug 9 Shots", isDirectory: true)
        let aug11 = synthRoot.appendingPathComponent("Aug 11 Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: aug9, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aug11, withIntermediateDirectories: true)

        let ciCtx = CIContext()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let sampleImg = makeGradientCIImage(width: 1200, height: 800)
        for i in 1...16 {
            try ciCtx.writeJPEGRepresentation(
                of: sampleImg,
                to: aug9.appendingPathComponent(String(format: "Shot_0809_%02d.jpg", i)),
                colorSpace: cs,
                options: [:]
            )
        }
        for i in 1...14 {
            try ciCtx.writeJPEGRepresentation(
                of: sampleImg,
                to: aug11.appendingPathComponent(String(format: "Shot_0811_%02d.jpg", i)),
                colorSpace: cs,
                options: [:]
            )
        }
        return synthRoot
    }

    // MARK: - 1. Graph Topology & Dry-Run Consistency

    func testStarterGraphDryRunCounts30ReadAnd30Write() throws {
        let demoRoot = try demoAssetsDirectory()
        let doc = WorkflowDocumentModel.makeStarterDocument(demoAssetsRoot: demoRoot)
        let summary = DryRunEstimator.estimate(document: doc)

        XCTAssertEqual(summary.readyToRead, 30)
        XCTAssertEqual(summary.readyToWrite, 30)
        XCTAssertEqual(summary.statusText, "30 assets ready to read, 30 to write.")

        let readNodes = doc.nodes.filter { $0.typeID == NodeTypeID.readFolder }
        XCTAssertEqual(readNodes.count, 2)
        let counts = Set(readNodes.compactMap { summary.nodeCounts[$0.id] })
        XCTAssertEqual(counts, [16, 14])
    }

    func testMultiScaleDoublesWriteCountTo60() throws {
        let demoRoot = try demoAssetsDirectory()
        var doc = WorkflowDocumentModel.makeStarterDocument(demoAssetsRoot: demoRoot)

        let scaleNode = try XCTUnwrap(doc.nodes.first { $0.typeID == NodeTypeID.scale })
        let writeNode = try XCTUnwrap(doc.nodes.first { $0.typeID == NodeTypeID.writeImages })

        let multiScale = WorkflowNode(
            typeID: NodeTypeID.multiScale,
            position: GraphPoint(x: 560, y: 90),
            parameters: [
                "scales": .scales([
                    ScaleBranchSpec(label: "1x", scaleFactor: 0.5, suffix: ""),
                    ScaleBranchSpec(label: "2x", scaleFactor: 1.0, suffix: "@2x")
                ])
            ]
        )
        doc.nodes.append(multiScale)
        doc.edges.removeAll { $0.sourceNodeID == scaleNode.id && $0.targetNodeID == writeNode.id }
        doc.edges.append(WorkflowEdge(sourceNodeID: scaleNode.id, targetNodeID: multiScale.id))
        doc.edges.append(WorkflowEdge(sourceNodeID: multiScale.id, targetNodeID: writeNode.id))

        let summary = DryRunEstimator.estimate(document: doc)
        XCTAssertEqual(summary.readyToRead, 30)
        XCTAssertEqual(summary.readyToWrite, 60)
        XCTAssertEqual(summary.statusText, "30 assets ready to read, 60 to write.")
    }

    func testCycleDetectionPreventsCycles() {
        let a = WorkflowNode(typeID: NodeTypeID.readFolder, position: GraphPoint(x: 0, y: 0))
        let b = WorkflowNode(typeID: NodeTypeID.scale, position: GraphPoint(x: 150, y: 0))
        let c = WorkflowNode(typeID: NodeTypeID.writeImages, position: GraphPoint(x: 300, y: 0))
        let doc = WorkflowDocumentModel(
            nodes: [a, b, c],
            edges: [
                WorkflowEdge(sourceNodeID: a.id, targetNodeID: b.id),
                WorkflowEdge(sourceNodeID: b.id, targetNodeID: c.id)
            ]
        )

        XCTAssertFalse(doc.canConnect(from: a.id, to: a.id))
        XCTAssertFalse(doc.canConnect(from: c.id, to: a.id))
        XCTAssertTrue(doc.canConnect(from: a.id, to: c.id))
    }

    // MARK: - 2. Coalesced UndoManager

    @MainActor
    func testCoalescedDragRegistersSingleUndoAction() {
        let a = WorkflowNode(typeID: NodeTypeID.scale, position: GraphPoint(x: 100, y: 100))
        let doc = WorkflowDocumentModel(nodes: [a], edges: [])
        let store = WorkflowStore(document: doc)

        store.beginContinuousEdit()
        for step in 1...10 {
            store.updateNodePositionsTransient([a.id: GraphPoint(x: 100 + Double(step * 15), y: 100)])
        }
        store.commitContinuousEdit(actionName: "Move Node")

        XCTAssertEqual(store.document.nodes.first?.position.x, 250)
        XCTAssertTrue(store.undoManager.canUndo)

        store.undoManager.undo()
        XCTAssertEqual(store.document.nodes.first?.position.x, 100)

        store.undoManager.redo()
        XCTAssertEqual(store.document.nodes.first?.position.x, 250)
    }

    // MARK: - 3. Token Expansion

    func testTokenExpansion() {
        let ci = makeGradientCIImage(width: 800, height: 533)
        let asset = PipelineAsset(
            fileName: "Sunset_Ocean",
            fileExtension: "jpg",
            parentFolderName: "Aug 9 Shots",
            ciImage: ci,
            metadata: [
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFArtist as String: "Emirhan",
                    kCGImagePropertyTIFFModel as String: "FB-1"
                ]
            ],
            dpi: 300,
            sequenceIndex: 7
        )
        let expanded = TokenExpander.expand("[File Name]_[Width]x[Height]_[Counter]_[Author]_[DPI]", for: asset)
        XCTAssertEqual(expanded, "Sunset_Ocean_800x533_007_Emirhan_300")
    }

    // MARK: - 4. Manual Indexed PNG Quantizer (Chunks, PLTE, tRNS, Crush)

    func testManualIndexedPNGProducesValidColorType3Chunks() throws {
        let ctx = CIContext()
        let img = makeGradientCIImage(width: 96, height: 64, includeAlpha: true)
        let data = try IndexedPNGQuantizer.encode(
            image: img,
            context: ctx,
            options: IndexedPNGOptions(
                maxColors: 16,
                speed: 1,
                dither: true,
                removeAlphaIfOpaque: true,
                removeColorProfile: true,
                crush: true,
                bruteForceCrush: false
            )
        )

        // Check PNG magic header
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let chunks = parsePNGChunkTypesAndPayloads(data)
        let types = chunks.map(\.type)
        XCTAssertEqual(types.first, "IHDR")
        XCTAssertEqual(types.last, "IEND")
        XCTAssertTrue(types.contains("PLTE"))
        XCTAssertTrue(types.contains("tRNS")) // Because includeAlpha: true
        XCTAssertFalse(types.contains("sRGB")) // Because removeColorProfile: true

        let ihdr = try XCTUnwrap(chunks.first { $0.type == "IHDR" }?.payload)
        XCTAssertEqual(ihdr[8], 4) // 16 colors fits cleanly in 4-bit indexed!
        XCTAssertEqual(ihdr[9], 3) // Color Type 3 = Indexed

        let plte = try XCTUnwrap(chunks.first { $0.type == "PLTE" }?.payload)
        XCTAssertLessThanOrEqual(plte.count / 3, 16)

        // Confirm ImageIO decodes our manual PNG cleanly
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.width, 96)
        XCTAssertEqual(cg.height, 64)
    }

    func testIndexedPNGBruteForceCrushIsCompact() throws {
        let ctx = CIContext()
        let img = makeGradientCIImage(width: 128, height: 96, includeAlpha: false)
        let standard = try IndexedPNGQuantizer.encode(
            image: img,
            context: ctx,
            options: IndexedPNGOptions(maxColors: 64, speed: 1, dither: false, crush: false, bruteForceCrush: false)
        )
        let crushed = try IndexedPNGQuantizer.encode(
            image: img,
            context: ctx,
            options: IndexedPNGOptions(maxColors: 64, speed: 1, dither: false, crush: true, bruteForceCrush: true)
        )
        XCTAssertLessThanOrEqual(crushed.count, standard.count)
    }

    private func parsePNGChunkTypesAndPayloads(_ data: Data) -> [(type: String, payload: Data)] {
        var result: [(String, Data)] = []
        var offset = 8
        while offset + 12 <= data.count {
            let len = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let typeData = data[(offset + 4)..<(offset + 8)]
            let type = String(data: typeData, encoding: .ascii) ?? ""
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + len
            guard payloadEnd + 4 <= data.count else { break }
            result.append((type, Data(data[payloadStart..<payloadEnd])))
            offset = payloadEnd + 4
        }
        return result
    }

    // MARK: - 5. Transform, Metadata, Rules & PDF Executors

    func testScaleFixedWidthAndRemoveGPSAndRules() async throws {
        let ci = makeGradientCIImage(width: 1200, height: 800)
        let asset = PipelineAsset(
            fileName: "Sample",
            fileExtension: "jpg",
            ciImage: ci,
            metadata: [
                kCGImagePropertyGPSDictionary as String: ["Latitude": 37.33],
                kCGImagePropertyExifDictionary as String: ["FNumber": 2.8]
            ]
        )

        let ctx = NodeExecutionContext(
            isPreview: true,
            previewContext: CIContext(),
            exportContext: CIContext()
        )

        // Scale to 800 width -> 800x533
        let scaleNode = WorkflowNode(typeID: NodeTypeID.scale, position: GraphPoint(x: 0, y: 0), parameters: [
            "mode": .string("Fixed Width"),
            "width": .int(800)
        ])
        let scaled = try TransformWatermarkExecutors.execute(asset: asset, node: scaleNode, context: ctx)[0].asset
        XCTAssertEqual(Int(scaled.pixelSize.width), 800)
        XCTAssertTrue((533...534).contains(Int(scaled.pixelSize.height)))

        // Remove GPS preserves EXIF
        let gpsNode = WorkflowNode(typeID: NodeTypeID.removeGPS, position: GraphPoint(x: 0, y: 0))
        let scrubbed = try MetadataSortExecutors.execute(asset: scaled, node: gpsNode, context: ctx)[0].asset
        XCTAssertNil(scrubbed.metadata[kCGImagePropertyGPSDictionary as String])
        XCTAssertNotNil(scrubbed.metadata[kCGImagePropertyExifDictionary as String])

        // Rules routes Width > 700 to port 0, else port 1
        let rulesNode = WorkflowNode(typeID: NodeTypeID.rules, position: GraphPoint(x: 0, y: 0), parameters: [
            "matchAll": .bool(true),
            "rules": .rules([FilterRule(field: .width, op: .greaterThan, value: "700")])
        ])
        let routedHigh = try MetadataSortExecutors.execute(asset: scrubbed, node: rulesNode, context: ctx)
        XCTAssertEqual(routedHigh[0].portIndex, 0)

        let smallAsset = PipelineAsset(fileName: "Small", ciImage: makeGradientCIImage(width: 400, height: 300))
        let routedLow = try MetadataSortExecutors.execute(asset: smallAsset, node: rulesNode, context: ctx)
        XCTAssertEqual(routedLow[0].portIndex, 1)
    }

    func testPDFMakerProducesValidMultiPagePDF() throws {
        let ctx = NodeExecutionContext(isPreview: false, previewContext: CIContext(), exportContext: CIContext())
        let assets = (1...3).map { i in
            PipelineAsset(fileName: "Page\(i)", ciImage: makeGradientCIImage(width: 200, height: 150))
        }
        let node = WorkflowNode(typeID: NodeTypeID.pdfMaker, position: GraphPoint(x: 0, y: 0), parameters: [
            "fileName": .string("Deck")
        ])
        let out = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: assets, node: node, context: ctx)
        XCTAssertEqual(out.count, 1)
        let pdfData = try XCTUnwrap(out[0].pdfData)
        let pdfDoc = try XCTUnwrap(PDFDocument(data: pdfData))
        XCTAssertEqual(pdfDoc.pageCount, 3)
    }

    // MARK: - 6. Sandboxed JavaScript Worker

    func testSandboxedJSWorkerIsolationAndWatchdogTimeout() async throws {
        guard let workerURL = DocumentGeneratorScriptExecutors.locateJSWorker() else {
            throw XCTSkip("FlowBatchJSWorker not built in test search path yet")
        }
        let ctx = NodeExecutionContext(
            isPreview: false,
            previewContext: CIContext(),
            exportContext: CIContext(),
            jsWorkerURL: workerURL
        )

        // 1. Valid script mutating output name
        let okAsset = PipelineAsset(fileName: "Photo", ciImage: makeGradientCIImage(width: 64, height: 64))
        let okNode = WorkflowNode(typeID: NodeTypeID.javaScript, position: GraphPoint(x: 0, y: 0), parameters: [
            "code": .string("function processAsset(asset) { asset.setOutputName(asset.fileName + '_js'); }")
        ])
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: okAsset, node: okNode, context: ctx)
        XCTAssertEqual(okAsset.outputNameOverride, "Photo_js")

        // 2. Cocoa / FileManager access blocked
        let badNode = WorkflowNode(typeID: NodeTypeID.javaScript, position: GraphPoint(x: 0, y: 0), parameters: [
            "code": .string("function processAsset(a) { return NSFileManager.defaultManager(); }")
        ])
        do {
            _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: okAsset.deepCopy(), node: badNode, context: ctx)
            XCTFail("Expected script error when referencing Cocoa APIs")
        } catch let NodeExecutionError.scriptFailed(msg) {
            XCTAssertTrue(msg.contains("ReferenceError") || msg.contains("Can't find variable"))
        }

        // 3. Infinite loop watchdog terminates within 2s budget
        let loopNode = WorkflowNode(typeID: NodeTypeID.javaScript, position: GraphPoint(x: 0, y: 0), parameters: [
            "code": .string("function processAsset(a) { while(true) {} }")
        ])
        do {
            _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: okAsset.deepCopy(), node: loopNode, context: ctx)
            XCTFail("Expected script timeout")
        } catch NodeExecutionError.scriptTimedOut {
            // Expected
        }
    }

    // MARK: - 7. Memory Budget & Downsampled Thumbnails

    func testThumbnailLoaderDownsamplesLargeImageToMax256() throws {
        let largeImg = makeGradientCIImage(width: 4096, height: 3072)
        let imgURL = tempDir.appendingPathComponent("large_4k.jpg")
        let ctx = CIContext()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        try ctx.writeJPEGRepresentation(of: largeImg, to: imgURL, colorSpace: cs, options: [:])

        let thumb = try XCTUnwrap(ThumbnailLoader.shared.loadThumbnail(for: imgURL, maxPixelSize: 256))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 256)
        XCTAssertGreaterThan(thumb.width, 0)
    }

    // MARK: - 8. JSON Persistence Round-Trip & Full 30-Asset Batch Pipeline

    @MainActor
    func testDocumentRoundTripAndFullBatchExportOf30DemoAssets() async throws {
        let demoRoot = try demoAssetsDirectory()
        var doc = WorkflowDocumentModel.makeStarterDocument(demoAssetsRoot: demoRoot)
        let outDir = tempDir.appendingPathComponent("ExportedThumbnails", isDirectory: true)

        if let idx = doc.nodes.firstIndex(where: { $0.typeID == NodeTypeID.writeImages }) {
            doc.nodes[idx].parameters["folderPath"] = .string(outDir.path)
            doc.nodes[idx].parameters["openFolderWhenFinished"] = .bool(false)
        }

        // JSON persistence round-trip
        let store = WorkflowStore(document: doc)
        let flowURL = tempDir.appendingPathComponent("TestWorkflow.flowbatch")
        try store.save(to: flowURL)
        let loadedData = try Data(contentsOf: flowURL)
        let decoded = try WorkflowStore.decodeDocument(from: loadedData)
        XCTAssertEqual(decoded.nodes.count, doc.nodes.count)
        XCTAssertEqual(decoded.edges.count, doc.edges.count)

        // Execute full batch pipeline across all 30 demo assets -> indexed PNG
        let runner = PipelineRunner()
        let summary = try await runner.runWorkflow(document: decoded)
        XCTAssertEqual(summary.writtenFiles.count, 30)
        XCTAssertTrue(summary.errors.isEmpty)

        // Verify first exported file is a valid 800px-wide indexed PNG
        let firstOut = try XCTUnwrap(summary.writtenFiles.first)
        let pngData = try Data(contentsOf: firstOut)
        let chunks = parsePNGChunkTypesAndPayloads(pngData)
        XCTAssertTrue(chunks.contains { $0.type == "PLTE" })
        let src = try XCTUnwrap(CGImageSourceCreateWithData(pngData as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.width, 800)
    }

    // MARK: - 9. Ask-on-Run Cancellation, Color/Blur Filters & Delete Metadata

    func testAskOnRunCancellationAbortsCleanly() async throws {
        let readNode = WorkflowNode(typeID: NodeTypeID.blankImage, position: GraphPoint(x: 0, y: 0))
        let writeNode = WorkflowNode(
            typeID: NodeTypeID.writeImages,
            position: GraphPoint(x: 150, y: 0),
            parameters: ["askForOutputFolder": .bool(true)]
        )
        let doc = WorkflowDocumentModel(
            nodes: [readNode, writeNode],
            edges: [WorkflowEdge(sourceNodeID: readNode.id, targetNodeID: writeNode.id)]
        )
        let runner = PipelineRunner()
        do {
            _ = try await runner.runWorkflow(document: doc, promptService: NoopPromptService())
            XCTFail("Expected userCancelled error when prompt returns nil")
        } catch NodeExecutionError.userCancelled {
            // Expected
        }
    }

    func testDeleteMetadataAndColorFilterPipeline() throws {
        let img = makeGradientCIImage(width: 240, height: 180)
        let asset = PipelineAsset(
            fileName: "FilterSample",
            ciImage: img,
            metadata: [
                kCGImagePropertyOrientation as String: 6,
                kCGImagePropertyExifDictionary as String: ["FNumber": 1.8],
                kCGImagePropertyGPSDictionary as String: ["Latitude": 48.1]
            ]
        )
        let ctx = NodeExecutionContext(isPreview: true, previewContext: CIContext(), exportContext: CIContext())

        let blurNode = WorkflowNode(typeID: NodeTypeID.gaussianBlur, position: GraphPoint(x: 0, y: 0), parameters: ["radius": .double(5)])
        let blurred = try ColorFilterExecutors.execute(asset: asset, node: blurNode, context: ctx)[0].asset
        XCTAssertEqual(Int(blurred.pixelSize.width), 240)

        let delNode = WorkflowNode(typeID: NodeTypeID.deleteMetadata, position: GraphPoint(x: 0, y: 0), parameters: ["keepOrientation": .bool(true)])
        let stripped = try MetadataSortExecutors.execute(asset: blurred, node: delNode, context: ctx)[0].asset
        XCTAssertNil(stripped.metadata[kCGImagePropertyExifDictionary as String])
        XCTAssertNil(stripped.metadata[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(stripped.metadata[kCGImagePropertyOrientation as String] as? Int, 6)
    }
}
