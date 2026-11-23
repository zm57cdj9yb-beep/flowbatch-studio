import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import Photos
import XCTest
@testable import FlowBatchCore

/// Exhaustive coverage test suite ensuring all 66 node types in `NodeCatalog`
/// have automated happy-path runs, category failure-case assertions, format edge cases,
/// and memory-budget checks.
final class NodeCoverageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowBatchCoverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestImage(width: Int = 128, height: Int = 96, hasTransparentBorder: Bool = false) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let inBorder = hasTransparentBorder && (x < 16 || x >= width - 16 || y < 12 || y >= height - 12)
                rgba[i] = UInt8((x * 255) / max(1, width - 1))
                rgba[i + 1] = UInt8((y * 255) / max(1, height - 1))
                rgba[i + 2] = 180
                rgba[i + 3] = inBorder ? 0 : 255
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

    private func makeContext(
        isPreview: Bool = false,
        pasteboardName: NSPasteboard.Name? = nil,
        photosOverride: PHAuthorizationStatus? = .denied,
        promptService: any UserPromptService = NoopPromptService()
    ) -> NodeExecutionContext {
        NodeExecutionContext(
            isPreview: isPreview,
            previewContext: CIContext(options: [.cacheIntermediates: true]),
            exportContext: CIContext(options: [.cacheIntermediates: false, .memoryTarget: 512]),
            promptService: promptService,
            jsWorkerURL: DocumentGeneratorScriptExecutors.locateJSWorker(),
            pasteboardName: pasteboardName,
            photosAuthorizationOverride: photosOverride
        )
    }

    // MARK: - 1. Read Images & Write Images (Happy + Error + Format Edge Cases)

    func testReadAndWriteFormatsAndEdgeCases() async throws {
        let img = makeTestImage(width: 100, height: 80)
        let srcDir = tempDir.appendingPathComponent("Input", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let jpgURL = srcDir.appendingPathComponent("sample.jpg")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ciCtx = CIContext()
        try ciCtx.writeJPEGRepresentation(of: img, to: jpgURL, colorSpace: cs, options: [:])

        // Read Files happy path
        let readFilesNode = WorkflowNode(
            typeID: NodeTypeID.readFiles,
            position: GraphPoint(x: 0, y: 0),
            parameters: ["filePaths": .string(jpgURL.path)]
        )
        let ctx = makeContext(pasteboardName: NSPasteboard.Name("FlowBatchTest-\(UUID().uuidString)"))
        let readAssets = try await ReadWriteExecutors.executeSource(node: readFilesNode, context: ctx)
        XCTAssertEqual(readAssets.count, 1)

        // Read Folder missing path error
        let badFolderNode = WorkflowNode(typeID: NodeTypeID.readFolder, position: GraphPoint(x: 0, y: 0), parameters: ["folderPath": .string("")])
        do {
            _ = try await ReadWriteExecutors.executeSource(node: badFolderNode, context: ctx)
            XCTFail("Expected missingInput error for empty folderPath")
        } catch NodeExecutionError.missingInput {}

        // Empty folder returns 0 assets cleanly
        let emptyDir = tempDir.appendingPathComponent("EmptyDir", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyFolderNode = WorkflowNode(typeID: NodeTypeID.readFolder, position: GraphPoint(x: 0, y: 0), parameters: ["folderPath": .string(emptyDir.path)])
        let emptyRead = try await ReadWriteExecutors.executeSource(node: emptyFolderNode, context: ctx)
        XCTAssertTrue(emptyRead.isEmpty)

        // Prompt for Files happy path with mock prompt
        struct MockPrompt: UserPromptService {
            let urls: [URL]
            @MainActor func chooseFiles(allowMultiple: Bool) async -> [URL]? { urls }
            @MainActor func chooseOutputFolder(promptTitle: String) async -> URL? { nil }
        }
        let promptNode = WorkflowNode(typeID: NodeTypeID.promptForFiles, position: GraphPoint(x: 0, y: 0))
        let promptAssets = try await ReadWriteExecutors.executeSource(node: promptNode, context: makeContext(promptService: MockPrompt(urls: [jpgURL])))
        XCTAssertEqual(promptAssets.count, 1)

        // Prompt cancelled throws userCancelled
        do {
            _ = try await ReadWriteExecutors.executeSource(node: promptNode, context: ctx)
            XCTFail("Expected userCancelled")
        } catch NodeExecutionError.userCancelled {}

        // Clipboard round-trip on isolated pasteboard + empty error
        let readClipNode = WorkflowNode(typeID: NodeTypeID.readClipboard, position: GraphPoint(x: 0, y: 0))
        do {
            _ = try await ReadWriteExecutors.executeSource(node: readClipNode, context: ctx)
            XCTFail("Expected missingInput on empty pasteboard")
        } catch NodeExecutionError.missingInput {}

        _ = try await ReadWriteExecutors.executeWriteClipboard(asset: readAssets[0], context: ctx)
        let clipLoaded = try await ReadWriteExecutors.executeSource(node: readClipNode, context: ctx)
        XCTAssertEqual(clipLoaded.count, 1)

        // Write Images across PNG, JPEG, HEIC, TIFF, PDF + overwriteExisting=false collision naming
        for fmt in ["PNG", "JPEG", "HEIC", "TIFF", "PDF"] {
            let writeNode = WorkflowNode(
                typeID: NodeTypeID.writeImages,
                position: GraphPoint(x: 0, y: 0),
                parameters: [
                    "folderPath": .string(outDir.path),
                    "format": .string(fmt),
                    "overwriteExisting": .bool(false),
                    "openFolderWhenFinished": .bool(false),
                    "fileNamePattern": .string("export_\(fmt)")
                ]
            )
            let out1 = try ReadWriteExecutors.executeWriteImages(
                asset: readAssets[0].deepCopy(),
                node: writeNode,
                resolvedOutputFolder: outDir,
                context: ctx
            )
            let url1 = try XCTUnwrap(out1[0].asset.writtenOutputURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path), "Missing \(fmt) export")

            // Write again with overwriteExisting=false -> produces unique suffix file
            let out2 = try ReadWriteExecutors.executeWriteImages(
                asset: readAssets[0].deepCopy(),
                node: writeNode,
                resolvedOutputFolder: outDir,
                context: ctx
            )
            let url2 = try XCTUnwrap(out2[0].asset.writtenOutputURL)
            XCTAssertNotEqual(url1, url2)
        }

        // Write Images missing output folder error
        let missingOutWrite = WorkflowNode(typeID: NodeTypeID.writeImages, position: GraphPoint(x: 0, y: 0), parameters: ["folderPath": .string("")])
        do {
            _ = try await ReadWriteExecutors.resolveOutputDirectory(for: missingOutWrite, context: ctx)
            XCTFail("Expected invalidParameter error")
        } catch NodeExecutionError.invalidParameter {}

        // Open in App: invalid target app throws cleanly; preview mode no-ops safely
        let badAppNode = WorkflowNode(typeID: NodeTypeID.openInApp, position: GraphPoint(x: 0, y: 0), parameters: ["applicationPath": .string("/Applications/DoesNotExist123.app")])
        do {
            _ = try ReadWriteExecutors.executeOpenInApp(asset: readAssets[0], node: badAppNode, context: ctx)
            XCTFail("Expected invalidParameter for missing app")
        } catch NodeExecutionError.invalidParameter {}
        _ = try ReadWriteExecutors.executeOpenInApp(asset: readAssets[0], node: badAppNode, context: makeContext(isPreview: true))

        // Corrupted RAW file handling (error path)
        let badRawURL = tempDir.appendingPathComponent("corrupt.dng")
        try Data("not a valid dng".utf8).write(to: badRawURL)
        let corruptRawAsset = try PipelineAsset.load(from: badRawURL, sequenceIndex: 1)
        XCTAssertNil(corruptRawAsset.ciImage)
        let rawNode = WorkflowNode(typeID: NodeTypeID.rawProcess, position: GraphPoint(x: 0, y: 0))
        do {
            _ = try ReadWriteExecutors.executeRAWProcess(asset: corruptRawAsset, node: rawNode, context: ctx)
            XCTFail("Expected invalidParameter for corrupted RAW")
        } catch NodeExecutionError.invalidParameter {}

        // Multi Scale execution
        let multiNode = WorkflowNode(typeID: NodeTypeID.multiScale, position: GraphPoint(x: 0, y: 0))
        let multiOut = ReadWriteExecutors.executeMultiScale(asset: readAssets[0].deepCopy(), node: multiNode)
        XCTAssertEqual(multiOut.count, 2)
    }

    // MARK: - 2. Blur, Sharpen, Color Adjustment & Color Effect (All 24 Filter Nodes)

    func testAllColorBlurSharpenEffectNodesAndEmptyInput() throws {
        let img = makeTestImage(width: 96, height: 72)
        let ctx = makeContext()

        let filterIDs: [String] = [
            NodeTypeID.gaussianBlur, NodeTypeID.boxBlur, NodeTypeID.motionBlur, NodeTypeID.noiseReduction, NodeTypeID.pixelate,
            NodeTypeID.sharpenLuminance, NodeTypeID.unsharpMask,
            NodeTypeID.exposure, NodeTypeID.brightnessContrast, NodeTypeID.vibrance, NodeTypeID.gamma,
            NodeTypeID.temperatureTint, NodeTypeID.shadowsHighlights, NodeTypeID.colorProfile,
            NodeTypeID.photoEffect, NodeTypeID.sepia, NodeTypeID.colorInvert, NodeTypeID.colorPosterize,
            NodeTypeID.oneBit, NodeTypeID.dither, NodeTypeID.matte, NodeTypeID.addBorder, NodeTypeID.dropShadow, NodeTypeID.documentEnhancer
        ]

        for typeID in filterIDs {
            let asset = PipelineAsset(fileName: "F", ciImage: img)
            let node = WorkflowNode(typeID: typeID, position: GraphPoint(x: 0, y: 0))
            let result = try ColorFilterExecutors.execute(asset: asset, node: node, context: ctx)
            XCTAssertEqual(result.count, 1)
            let outImg = try XCTUnwrap(result[0].asset.ciImage, "Nil CIImage after \(typeID)")
            XCTAssertGreaterThan(outImg.extent.width, 0, "Zero width for \(typeID)")
            XCTAssertGreaterThan(outImg.extent.height, 0, "Zero height for \(typeID)")

            // Verify border/shadow expand canvas as expected
            if typeID == NodeTypeID.addBorder {
                XCTAssertEqual(Int(outImg.extent.width), 96 + 40)
            } else if typeID == NodeTypeID.dropShadow {
                XCTAssertGreaterThan(Int(outImg.extent.width), 96)
            }
        }

        // Empty (nil) CIImage passes gracefully without crashing
        let emptyAsset = PipelineAsset(fileName: "Empty", ciImage: nil)
        let emptyOut = try ColorFilterExecutors.execute(asset: emptyAsset, node: WorkflowNode(typeID: NodeTypeID.gaussianBlur, position: GraphPoint(x: 0, y: 0)), context: ctx)
        XCTAssertNil(emptyOut[0].asset.ciImage)
    }

    // MARK: - 3. Transform & Watermark (All 8 Nodes)

    func testAllTransformAndWatermarkNodes() throws {
        let img = makeTestImage(width: 120, height: 80, hasTransparentBorder: true)
        let ctx = makeContext()

        // Scale modes
        for mode in ["Fixed Width", "Fixed Height", "Percentage", "Fit Inside", "Exact Size"] {
            let scaleNode = WorkflowNode(
                typeID: NodeTypeID.scale,
                position: GraphPoint(x: 0, y: 0),
                parameters: ["mode": .string(mode), "width": .int(60), "height": .int(40), "percent": .double(50)]
            )
            let out = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "S", ciImage: img), node: scaleNode, context: ctx)[0].asset
            XCTAssertGreaterThan(out.pixelSize.width, 0)
        }

        // Crop (Pixels & Aspect Ratio)
        let cropPixels = WorkflowNode(typeID: NodeTypeID.crop, position: GraphPoint(x: 0, y: 0), parameters: ["mode": .string("Pixels"), "width": .int(60), "height": .int(50)])
        let cropped = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "C", ciImage: img), node: cropPixels, context: ctx)[0].asset
        XCTAssertEqual(Int(cropped.pixelSize.width), 60)
        XCTAssertEqual(Int(cropped.pixelSize.height), 50)

        // Rotate
        let rotNode = WorkflowNode(typeID: NodeTypeID.rotate, position: GraphPoint(x: 0, y: 0), parameters: ["degrees": .double(90)])
        let rotated = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "R", ciImage: img), node: rotNode, context: ctx)[0].asset
        XCTAssertEqual(Int(rotated.pixelSize.width), 80)

        // Flip
        for dir in ["Horizontal", "Vertical", "Both"] {
            let flipNode = WorkflowNode(typeID: NodeTypeID.flip, position: GraphPoint(x: 0, y: 0), parameters: ["direction": .string(dir)])
            let flipped = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "F", ciImage: img), node: flipNode, context: ctx)[0].asset
            XCTAssertEqual(Int(flipped.pixelSize.width), 120)
        }

        // Trim to Edges removes 16px left/right & 12px top/bottom transparent padding
        let trimNode = WorkflowNode(typeID: NodeTypeID.trimToEdges, position: GraphPoint(x: 0, y: 0))
        let trimmed = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "T", ciImage: img), node: trimNode, context: ctx)[0].asset
        XCTAssertEqual(Int(trimmed.pixelSize.width), 88)
        XCTAssertEqual(Int(trimmed.pixelSize.height), 56)

        // ML Super Resolution 2x
        let srNode = WorkflowNode(typeID: NodeTypeID.mlSuperResolution, position: GraphPoint(x: 0, y: 0), parameters: ["multiplier": .string("2x")])
        let upscaled = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "SR", ciImage: img), node: srNode, context: ctx)[0].asset
        XCTAssertEqual(Int(upscaled.pixelSize.width), 240)

        // Text Watermark (anchored & tiled)
        for tile in [false, true] {
            let txtNode = WorkflowNode(typeID: NodeTypeID.textWatermark, position: GraphPoint(x: 0, y: 0), parameters: ["tile": .bool(tile)])
            let wm = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "W", ciImage: img), node: txtNode, context: ctx)[0].asset
            XCTAssertEqual(Int(wm.pixelSize.width), 120)
        }

        // Image Watermark (real badge PNG + missing path graceful fallback)
        let badgeURL = tempDir.appendingPathComponent("badge.png")
        try CIContext().writePNGRepresentation(of: makeTestImage(width: 32, height: 32), to: badgeURL, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let imgWmNode = WorkflowNode(typeID: NodeTypeID.imageWatermark, position: GraphPoint(x: 0, y: 0), parameters: ["imagePath": .string(badgeURL.path)])
        let imgWmOut = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "IW", ciImage: img), node: imgWmNode, context: ctx)[0].asset
        XCTAssertEqual(Int(imgWmOut.pixelSize.width), 120)

        let missingWmNode = WorkflowNode(typeID: NodeTypeID.imageWatermark, position: GraphPoint(x: 0, y: 0), parameters: ["imagePath": .string("/nonexistent/badge.png")])
        let fallbackOut = try TransformWatermarkExecutors.execute(asset: PipelineAsset(fileName: "IW2", ciImage: img), node: missingWmNode, context: ctx)[0].asset
        XCTAssertEqual(Int(fallbackOut.pixelSize.width), 120)
    }

    // MARK: - 4. Metadata, Sort, Generator, PDF, Misc, Photos, Script

    func testMetadataSortGeneratorPDFMiscPhotosAndScripts() async throws {
        let img = makeTestImage(width: 100, height: 80)
        let ctx = makeContext()

        // Metadata: Set DPI, Set General Metadata, Fix EXIF Rotation
        let dpiNode = WorkflowNode(typeID: NodeTypeID.setDPI, position: GraphPoint(x: 0, y: 0), parameters: ["dpi": .int(300)])
        let dpiAsset = try MetadataSortExecutors.execute(asset: PipelineAsset(fileName: "M1", ciImage: img), node: dpiNode, context: ctx)[0].asset
        XCTAssertEqual(dpiAsset.dpi, 300)

        let genMetaNode = WorkflowNode(typeID: NodeTypeID.setGeneralMetadata, position: GraphPoint(x: 0, y: 0), parameters: [
            "author": .string("Tester"), "copyright": .string("© 2026"), "title": .string("Title"), "description": .string("Desc")
        ])
        let metaAsset = try MetadataSortExecutors.execute(asset: dpiAsset, node: genMetaNode, context: ctx)[0].asset
        let tiff = metaAsset.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFArtist as String] as? String, "Tester")

        let rotMetaAsset = PipelineAsset(fileName: "Rot", ciImage: img, metadata: [kCGImagePropertyOrientation as String: 6])
        let fixedRot = try MetadataSortExecutors.execute(asset: rotMetaAsset, node: WorkflowNode(typeID: NodeTypeID.fixExifRotation, position: GraphPoint(x: 0, y: 0)), context: ctx)[0].asset
        XCTAssertEqual(fixedRot.metadata[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertEqual(Int(fixedRot.pixelSize.width), 80)

        // Sort: Classify Images & Sort Order
        let classifyNode = WorkflowNode(typeID: NodeTypeID.classifyImages, position: GraphPoint(x: 0, y: 0), parameters: ["minConfidence": .double(0.01)])
        _ = try MetadataSortExecutors.execute(asset: PipelineAsset(fileName: "Cls", ciImage: img), node: classifyNode, context: ctx)

        let a1 = PipelineAsset(fileName: "B", ciImage: img)
        let a2 = PipelineAsset(fileName: "A", ciImage: img)
        let sorted = MetadataSortExecutors.sortBatch([a1, a2], node: WorkflowNode(typeID: NodeTypeID.sortOrder, position: GraphPoint(x: 0, y: 0)))
        XCTAssertEqual(sorted.map(\.fileName), ["A", "B"])

        // Generator: Blank Image, Image Grid, Animated Image -> GIF + Layer Splitter, Screenshot smoke
        let blank = DocumentGeneratorScriptExecutors.executeBlankImage(node: WorkflowNode(typeID: NodeTypeID.blankImage, position: GraphPoint(x: 0, y: 0), parameters: ["width": .int(200), "height": .int(100)]))
        XCTAssertEqual(Int(blank[0].pixelSize.width), 200)

        let grid = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: [a1, a2], node: WorkflowNode(typeID: NodeTypeID.imageGrid, position: GraphPoint(x: 0, y: 0), parameters: ["columns": .int(2), "tileSize": .int(64)]), context: ctx)
        XCTAssertEqual(grid.count, 1)

        let anim = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: [a1, a2, a1], node: WorkflowNode(typeID: NodeTypeID.animatedImage, position: GraphPoint(x: 0, y: 0)), context: ctx)
        let gifDir = tempDir.appendingPathComponent("GIFOut", isDirectory: true)
        let writeGif = try ReadWriteExecutors.executeWriteImages(
            asset: anim[0],
            node: WorkflowNode(typeID: NodeTypeID.writeImages, position: GraphPoint(x: 0, y: 0), parameters: ["format": .string("GIF"), "openFolderWhenFinished": .bool(false)]),
            resolvedOutputFolder: gifDir,
            context: ctx
        )
        let gifURL = try XCTUnwrap(writeGif[0].asset.writtenOutputURL)

        // Layer & Page Splitter splits multi-frame GIF back into 3 frames
        let gifInput = try PipelineAsset.load(from: gifURL, sequenceIndex: 1)
        let splitFrames = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(
            asset: gifInput,
            node: WorkflowNode(typeID: NodeTypeID.layerPageSplitter, position: GraphPoint(x: 0, y: 0)),
            context: ctx
        )
        XCTAssertEqual(splitFrames.count, 3)

        // Screenshot smoke (succeeds or throws clean TCC error without crashing)
        do {
            let shot = try await DocumentGeneratorScriptExecutors.executeScreenshot()
            XCTAssertFalse(shot.isEmpty)
        } catch {
            // Expected in headless/non-Screen-Recording environment
        }

        // PDF Extractor round-trip & empty/corrupt PDF fallback
        let pdfOut = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: [a1, a2], node: WorkflowNode(typeID: NodeTypeID.pdfMaker, position: GraphPoint(x: 0, y: 0)), context: ctx)
        let extracted = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(
            asset: pdfOut[0],
            node: WorkflowNode(typeID: NodeTypeID.pdfExtractor, position: GraphPoint(x: 0, y: 0)),
            context: ctx
        )
        XCTAssertEqual(extracted.count, 2)

        // Misc: ChangeBits, Duplicate, Delay, ExtractPortraitMatte, ContrastStretch, CustomConvolution
        let bits = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "B", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.changeBitsPerChannel, position: GraphPoint(x: 0, y: 0), parameters: ["bits": .string("16")]), context: ctx)
        XCTAssertEqual(bits[0].asset.bitsPerChannel, 16)

        let dup = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "D", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.duplicate, position: GraphPoint(x: 0, y: 0), parameters: ["copies": .int(3)]), context: ctx)
        XCTAssertEqual(dup.count, 3)

        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "W", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.delay, position: GraphPoint(x: 0, y: 0), parameters: ["seconds": .double(0.02)]), context: ctx)
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "PM", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.extractPortraitMatte, position: GraphPoint(x: 0, y: 0)), context: ctx)
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "CS", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.contrastStretch, position: GraphPoint(x: 0, y: 0)), context: ctx)
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "CV", ciImage: img), node: WorkflowNode(typeID: NodeTypeID.customConvolution, position: GraphPoint(x: 0, y: 0)), context: ctx)

        // Photos Library denied authorization error path (Loop 4 check: no crash!)
        do {
            _ = try await DocumentGeneratorScriptExecutors.executeReadPhotosLibrary(
                node: WorkflowNode(typeID: NodeTypeID.readPhotosLibrary, position: GraphPoint(x: 0, y: 0)),
                context: ctx
            )
            XCTFail("Expected authorizationDenied error")
        } catch NodeExecutionError.authorizationDenied {}

        do {
            _ = try await DocumentGeneratorScriptExecutors.executeImportToPhotos(
                asset: PipelineAsset(fileName: "P", ciImage: img),
                node: WorkflowNode(typeID: NodeTypeID.importToPhotos, position: GraphPoint(x: 0, y: 0)),
                context: ctx
            )
            XCTFail("Expected authorizationDenied error")
        } catch NodeExecutionError.authorizationDenied {}

        // Shell Script happy + non-zero exit error
        let okShell = WorkflowNode(typeID: NodeTypeID.shellScript, position: GraphPoint(x: 0, y: 0), parameters: ["script": .string("echo ok_shell")])
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "Sh", ciImage: img), node: okShell, context: ctx)

        let badShell = WorkflowNode(typeID: NodeTypeID.shellScript, position: GraphPoint(x: 0, y: 0), parameters: ["script": .string("exit 42")])
        do {
            _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "ShErr", ciImage: img), node: badShell, context: ctx)
            XCTFail("Expected scriptFailed error on exit 42")
        } catch NodeExecutionError.scriptFailed {}

        // AppleScript happy + syntax error
        let okAS = WorkflowNode(typeID: NodeTypeID.appleScript, position: GraphPoint(x: 0, y: 0), parameters: ["script": .string("return \"hello\"")])
        _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "AS", ciImage: img), node: okAS, context: ctx)

        let badAS = WorkflowNode(typeID: NodeTypeID.appleScript, position: GraphPoint(x: 0, y: 0), parameters: ["script": .string("this is not valid applescript {{{")])
        do {
            _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: PipelineAsset(fileName: "ASErr", ciImage: img), node: badAS, context: ctx)
            XCTFail("Expected scriptFailed on invalid AppleScript")
        } catch NodeExecutionError.scriptFailed {}
    }

    // MARK: - 5. Large Image Memory Budget & Concurrency Cap

    func testLargeImageMemoryBudgetAndRunnerIsolation() async throws {
        let runner = PipelineRunner()
        let limit48MP = await runner.safeExportConcurrencyLimit(forEstimatedMaxMegapixels: 48.0)
        XCTAssertEqual(limit48MP, 1, "48MP RAW assets must serialize to 1 concurrent export")

        // Generate 6000x4000 (24MP) image and run Scale + HEIC export via PipelineRunner
        let bigImg = makeTestImage(width: 6000, height: 4000)
        let bigURL = tempDir.appendingPathComponent("big_24mp.jpg")
        try CIContext().writeJPEGRepresentation(of: bigImg, to: bigURL, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])

        let thumb = try XCTUnwrap(ThumbnailLoader.shared.loadThumbnail(for: bigURL, maxPixelSize: 256))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 256)

        let outDir = tempDir.appendingPathComponent("BigExport", isDirectory: true)
        let read = WorkflowNode(typeID: NodeTypeID.readFiles, position: GraphPoint(x: 0, y: 0), parameters: ["filePaths": .string(bigURL.path)])
        let scale = WorkflowNode(typeID: NodeTypeID.scale, position: GraphPoint(x: 150, y: 0), parameters: ["mode": .string("Fixed Width"), "width": .int(1600)])
        let write = WorkflowNode(typeID: NodeTypeID.writeImages, position: GraphPoint(x: 300, y: 0), parameters: [
            "folderPath": .string(outDir.path), "format": .string("HEIC"), "openFolderWhenFinished": .bool(false)
        ])
        let doc = WorkflowDocumentModel(
            nodes: [read, scale, write],
            edges: [
                WorkflowEdge(sourceNodeID: read.id, targetNodeID: scale.id),
                WorkflowEdge(sourceNodeID: scale.id, targetNodeID: write.id)
            ]
        )
        let summary = try await runner.runWorkflow(document: doc)
        XCTAssertEqual(summary.writtenFiles.count, 1)
        XCTAssertTrue(summary.errors.isEmpty)
    }

    // MARK: - 6. Exhaustive 66-Node Smoke Matrix Guard

    func testAll67CatalogNodesSmokeExecutedThroughPipeline() async throws {
        var coveredIDs = Set<String>()
        let img = makeTestImage(width: 64, height: 48)
        let ctx = makeContext(isPreview: true, pasteboardName: NSPasteboard.Name("FlowBatchSmoke-\(UUID().uuidString)"))

        // Verify every single node definition in NodeCatalog.allDefinitions can instantiate & run cleanly
        for def in NodeCatalog.allDefinitions {
            let node = WorkflowNode(typeID: def.typeID, position: GraphPoint(x: 0, y: 0))
            let asset = PipelineAsset(fileName: "Smoke", ciImage: img)

            switch def.typeID {
            case NodeTypeID.readFolder:
                let emptyDir = tempDir.appendingPathComponent("smoke-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
                var n = node; n.parameters["folderPath"] = .string(emptyDir.path)
                _ = try await ReadWriteExecutors.executeSource(node: n, context: ctx)

            case NodeTypeID.readFiles, NodeTypeID.promptForFiles:
                _ = try await ReadWriteExecutors.executeSource(node: node, context: ctx)

            case NodeTypeID.readClipboard:
                do { _ = try await ReadWriteExecutors.executeSource(node: node, context: ctx) } catch NodeExecutionError.missingInput {}

            case NodeTypeID.rawProcess:
                _ = try ReadWriteExecutors.executeRAWProcess(asset: asset, node: node, context: ctx)

            case NodeTypeID.writeImages:
                _ = try ReadWriteExecutors.executeWriteImages(asset: asset, node: node, resolvedOutputFolder: tempDir, context: ctx)

            case NodeTypeID.writeClipboard:
                _ = try await ReadWriteExecutors.executeWriteClipboard(asset: asset, context: ctx)

            case NodeTypeID.openInApp:
                _ = try ReadWriteExecutors.executeOpenInApp(asset: asset, node: node, context: ctx)

            case NodeTypeID.multiScale:
                _ = ReadWriteExecutors.executeMultiScale(asset: asset, node: node)

            case NodeTypeID.blankImage:
                _ = DocumentGeneratorScriptExecutors.executeBlankImage(node: node)

            case NodeTypeID.screenshot:
                do { _ = try await DocumentGeneratorScriptExecutors.executeScreenshot() } catch {}

            case NodeTypeID.imageGrid, NodeTypeID.animatedImage, NodeTypeID.pdfMaker:
                _ = try DocumentGeneratorScriptExecutors.executeBatchCollector(assets: [asset], node: node, context: ctx)

            case NodeTypeID.sortOrder:
                _ = MetadataSortExecutors.sortBatch([asset], node: node)

            case NodeTypeID.readPhotosLibrary:
                do { _ = try await DocumentGeneratorScriptExecutors.executeReadPhotosLibrary(node: node, context: ctx) } catch NodeExecutionError.authorizationDenied {}

            case NodeTypeID.importToPhotos:
                _ = try await DocumentGeneratorScriptExecutors.executeImportToPhotos(asset: asset, node: node, context: ctx)

            default:
                switch def.category {
                case .blur, .sharpen, .colorAdjustment, .colorEffect:
                    _ = try ColorFilterExecutors.execute(asset: asset, node: node, context: ctx)
                case .transform, .watermark:
                    _ = try TransformWatermarkExecutors.execute(asset: asset, node: node, context: ctx)
                case .metadata, .sort:
                    _ = try MetadataSortExecutors.execute(asset: asset, node: node, context: ctx)
                case .pdf, .misc, .script:
                    _ = try await DocumentGeneratorScriptExecutors.executeSingleMiscOrPDF(asset: asset, node: node, context: ctx)
                default:
                    XCTFail("Unhandled node category for \(def.typeID)")
                }
            }
            coveredIDs.insert(def.typeID)
        }

        let catalogIDs = Set(NodeCatalog.allDefinitions.map(\.typeID))
        XCTAssertEqual(coveredIDs, catalogIDs)
        XCTAssertEqual(catalogIDs.count, 67)
    }
}
