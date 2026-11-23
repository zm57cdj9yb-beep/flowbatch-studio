import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import Photos
import ScreenCaptureKit

/// Implements Generator (`Blank Image`, `Screenshot`, `Image Grid`, `Animated Image`),
/// PDF (`PDF Maker`, `PDF Image Extractor`), Misc (`Change Bits Per Channel`, `Duplicate`,
/// `Delay`, `Layer & Page Splitter`, `Extract Portrait Matte`, `Contrast Stretch`, `Custom Convolution`),
/// Photos Library (`Read Photos Library`, `Import to Photos`), and Script (`JavaScript`, `Shell Script`, `AppleScript`).
public enum DocumentGeneratorScriptExecutors {

    // MARK: - Generator Sources

    public static func executeBlankImage(node: WorkflowNode) -> [PipelineAsset] {
        let w = CGFloat(max(16, node.parameters["width"]?.intValue ?? 1200))
        let h = CGFloat(max(16, node.parameters["height"]?.intValue ?? 800))
        let color = node.parameters["color"]?.colorValue ?? .white
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let img = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: rect)
        return [PipelineAsset(fileName: "Blank Canvas", fileExtension: "png", ciImage: img)]
    }

    public static func executeScreenshot() async throws -> [PipelineAsset] {
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first else {
            throw NodeExecutionError.missingInput("No active display available for ScreenCaptureKit capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let ci = CIImage(cgImage: cgImage)
        return [PipelineAsset(fileName: "Screenshot", fileExtension: "png", ciImage: ci)]
    }

    // MARK: - Batch Collectors (Image Grid, Animated Image, PDF Maker)

    public static func executeBatchCollector(
        assets: [PipelineAsset],
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws -> [PipelineAsset] {
        guard !assets.isEmpty else { return [] }

        switch node.typeID {
        case NodeTypeID.imageGrid:
            let cols = max(1, node.parameters["columns"]?.intValue ?? 4)
            let tile = CGFloat(max(32, node.parameters["tileSize"]?.intValue ?? 256))
            let spacing = CGFloat(max(0, node.parameters["spacing"]?.intValue ?? 12))
            let bgColor = node.parameters["backgroundColor"]?.colorValue ?? .white

            let rows = Int(ceil(Double(assets.count) / Double(cols)))
            let totalW = CGFloat(cols) * tile + CGFloat(cols + 1) * spacing
            let totalH = CGFloat(rows) * tile + CGFloat(rows + 1) * spacing
            let canvasRect = CGRect(x: 0, y: 0, width: totalW, height: totalH)
            var composite = CIImage(color: CIColor(cgColor: bgColor.cgColor)).cropped(to: canvasRect)

            for (index, asset) in assets.enumerated() {
                guard let img = asset.ciImage, img.extent.width > 0, img.extent.height > 0 else { continue }
                let row = index / cols
                let col = index % cols
                let scale = min(tile / img.extent.width, tile / img.extent.height)
                let scaled = img.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0
                ])
                let x = spacing + CGFloat(col) * (tile + spacing) + (tile - scaled.extent.width) * 0.5 - scaled.extent.origin.x
                let y = totalH - spacing - CGFloat(row + 1) * tile - CGFloat(row) * spacing + (tile - scaled.extent.height) * 0.5 - scaled.extent.origin.y
                composite = scaled.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: composite)
            }

            let gridAsset = PipelineAsset(fileName: "Image Grid", fileExtension: "png", ciImage: composite.cropped(to: canvasRect))
            return [gridAsset]

        case NodeTypeID.animatedImage:
            let delay = max(0.02, node.parameters["frameDelay"]?.doubleValue ?? 0.25)
            let name = node.parameters["fileName"]?.stringValue ?? "Animated"
            let frames: [(CIImage, Double)] = assets.compactMap { a in
                guard let img = a.ciImage else { return nil }
                return (img, delay)
            }
            guard let first = frames.first else { return [] }
            let out = PipelineAsset(fileName: name.isEmpty ? "Animated" : name, fileExtension: "gif", ciImage: first.0)
            out.animatedFrames = frames
            return [out]

        case NodeTypeID.pdfMaker:
            let fileName = node.parameters["fileName"]?.stringValue ?? "Combined"
            let margin = CGFloat(max(0, node.parameters["margin"]?.intValue ?? 0))
            let pdfDoc = PDFDocument()
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

            for (idx, asset) in assets.enumerated() {
                guard let ci = asset.ciImage else { continue }
                guard let cg = context.activeCIContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: cs) else {
                    continue
                }
                let pageSize = NSSize(width: CGFloat(cg.width) + margin * 2, height: CGFloat(cg.height) + margin * 2)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(pageSize.width), pixelsHigh: Int(pageSize.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )
                if let rep {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSColor.white.setFill()
                    NSRect(origin: .zero, size: pageSize).fill()
                    NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        .draw(in: NSRect(x: margin, y: margin, width: CGFloat(cg.width), height: CGFloat(cg.height)))
                    NSGraphicsContext.restoreGraphicsState()
                    if let composedCG = rep.cgImage {
                        let pageImage = NSImage(cgImage: composedCG, size: pageSize)
                        if let page = PDFPage(image: pageImage) {
                            pdfDoc.insert(page, at: idx)
                        }
                    }
                }
            }
            guard let data = pdfDoc.dataRepresentation() else {
                throw NodeExecutionError.encodingFailed("PDFDocument failed to serialize.")
            }
            let out = PipelineAsset(
                fileName: fileName.isEmpty ? "Combined" : fileName,
                fileExtension: "pdf",
                ciImage: assets.first?.ciImage
            )
            out.pdfData = data
            return [out]

        default:
            return assets
        }
    }

    // MARK: - Single-Asset PDF / Misc Executors

    public static func executeSingleMiscOrPDF(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) async throws -> [RoutedAsset] {
        switch node.typeID {
        case NodeTypeID.pdfExtractor:
            let dpi = CGFloat(max(72, node.parameters["dpi"]?.intValue ?? 150))
            let scale = dpi / 72.0
            let pdf: PDFDocument?
            if let data = asset.pdfData {
                pdf = PDFDocument(data: data)
            } else if let url = asset.sourceURL, url.pathExtension.lowercased() == "pdf" {
                pdf = PDFDocument(url: url)
            } else {
                pdf = nil
            }
            guard let pdf, pdf.pageCount > 0 else {
                return [RoutedAsset(asset: asset)]
            }
            var out: [RoutedAsset] = []
            for p in 0..<pdf.pageCount {
                guard let page = pdf.page(at: p) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let w = max(1, Int(bounds.width * scale))
                let h = max(1, Int(bounds.height * scale))
                let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let cgCtx = CGContext(
                    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    cgCtx.setFillColor(CGColor.white)
                    cgCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    cgCtx.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: cgCtx)
                    if let cg = cgCtx.makeImage() {
                        let copy = asset.deepCopy(newIndex: p + 1)
                        copy.fileName = "\(asset.fileName)_page\(p + 1)"
                        copy.fileExtension = "png"
                        copy.pdfData = nil
                        copy.ciImage = CIImage(cgImage: cg)
                        out.append(RoutedAsset(asset: copy))
                    }
                }
            }
            return out.isEmpty ? [RoutedAsset(asset: asset)] : out

        case NodeTypeID.layerPageSplitter:
            if let url = asset.sourceURL, url.pathExtension.lowercased() == "pdf" {
                return try await executeSingleMiscOrPDF(
                    asset: asset,
                    node: WorkflowNode(typeID: NodeTypeID.pdfExtractor, position: node.position, parameters: ["dpi": .int(150)]),
                    context: context
                )
            }
            if let url = asset.sourceURL,
               let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let count = CGImageSourceGetCount(src)
                if count > 1 {
                    var pages: [RoutedAsset] = []
                    for i in 0..<count {
                        if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                            let copy = asset.deepCopy(newIndex: i + 1)
                            copy.fileName = "\(asset.fileName)_frame\(i + 1)"
                            copy.ciImage = CIImage(cgImage: cg)
                            pages.append(RoutedAsset(asset: copy))
                        }
                    }
                    return pages
                }
            }
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.changeBitsPerChannel:
            let bits = Int(node.parameters["bits"]?.stringValue ?? "8") ?? 8
            asset.bitsPerChannel = bits
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.duplicate:
            let copies = max(1, min(20, node.parameters["copies"]?.intValue ?? 2))
            return (0..<copies).map { idx in
                let copy = asset.deepCopy(newIndex: asset.sequenceIndex * copies + idx)
                if idx > 0 {
                    copy.outputNameOverride = "\(copy.outputNameOverride ?? copy.fileName)_\(idx + 1)"
                }
                return RoutedAsset(asset: copy)
            }

        case NodeTypeID.delay:
            if !context.isPreview {
                let seconds = max(0.01, node.parameters["seconds"]?.doubleValue ?? 0.5)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.extractPortraitMatte:
            if let url = asset.sourceURL,
               let matte = CIImage(contentsOf: url, options: [.auxiliaryPortraitEffectsMatte: true]) {
                asset.ciImage = matte
            }
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.contrastStretch:
            if let img = asset.ciImage {
                asset.ciImage = img.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.18,
                    kCIInputSaturationKey: 1.05
                ])
            }
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.customConvolution:
            if let img = asset.ciImage {
                let raw = node.parameters["weights"]?.stringValue ?? "0,-1,0,-1,5,-1,0,-1,0"
                let vals = raw.split(separator: ",").compactMap { CGFloat(Double($0.trimmingCharacters(in: .whitespaces)) ?? 0) }
                if vals.count == 9 {
                    let vec = CIVector(values: vals, count: 9)
                    let ext = img.extent
                    asset.ciImage = img.clampedToExtent()
                        .applyingFilter("CIConvolution3X3", parameters: [kCIInputWeightsKey: vec, kCIInputBiasKey: 0.0])
                        .cropped(to: ext)
                }
            }
            return [RoutedAsset(asset: asset)]

        // MARK: - Scripts
        case NodeTypeID.javaScript:
            if context.isPreview { return [RoutedAsset(asset: asset)] }
            try runSandboxedJavaScript(asset: asset, node: node, context: context)
            return asset.shouldSkip ? [] : [RoutedAsset(asset: asset)]

        case NodeTypeID.shellScript:
            if context.isPreview { return [RoutedAsset(asset: asset)] }
            try runShellScript(asset: asset, node: node, context: context)
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.appleScript:
            if context.isPreview { return [RoutedAsset(asset: asset)] }
            try runAppleScript(asset: asset, node: node, context: context)
            return [RoutedAsset(asset: asset)]

        default:
            return [RoutedAsset(asset: asset)]
        }
    }

    // MARK: - Photos Library (PhotoKit with Explicit Auth Flow)

    public static func resolvePhotosAuthorization(for level: PHAccessLevel, override: PHAuthorizationStatus?) async -> PHAuthorizationStatus {
        if let override { return override }
        let current = PHPhotoLibrary.authorizationStatus(for: level)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: level)
        }
        return current
    }

    public static func executeReadPhotosLibrary(
        node: WorkflowNode,
        context: NodeExecutionContext? = nil
    ) async throws -> [PipelineAsset] {
        let status = await resolvePhotosAuthorization(for: .readWrite, override: context?.photosAuthorizationOverride)
        guard status == .authorized || status == .limited else {
            throw NodeExecutionError.authorizationDenied(
                "Photos access denied. Open System Settings -> Privacy & Security -> Photos to grant FlowBatch Studio access."
            )
        }

        let albumName = (node.parameters["albumName"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, node.parameters["limit"]?.intValue ?? 25)

        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = limit
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let phAssets: PHFetchResult<PHAsset>
        if !albumName.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var matched: PHAssetCollection?
            collections.enumerateObjects { col, _, stop in
                if col.localizedTitle == albumName {
                    matched = col
                    stop.pointee = true
                }
            }
            guard let album = matched else {
                throw NodeExecutionError.missingInput("Photos album '\(albumName)' not found.")
            }
            phAssets = PHAsset.fetchAssets(in: album, options: fetchOptions)
        } else {
            phAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        }

        var items: [PHAsset] = []
        phAssets.enumerateObjects { asset, _, _ in items.append(asset) }

        var results: [PipelineAsset] = []
        let imgMgr = PHImageManager.default()
        let reqOpts = PHImageRequestOptions()
        reqOpts.isSynchronous = true
        reqOpts.isNetworkAccessAllowed = true
        reqOpts.deliveryMode = .highQualityFormat

        for (idx, phAsset) in items.enumerated() {
            try Task.checkCancellation()
            var loadedCI: CIImage?
            imgMgr.requestImageDataAndOrientation(for: phAsset, options: reqOpts) { data, _, _, _ in
                if let data {
                    loadedCI = CIImage(data: data, options: [.applyOrientationProperty: true])
                }
            }
            if let loadedCI {
                let p = PipelineAsset(
                    fileName: "Photo_\(idx + 1)",
                    fileExtension: "jpg",
                    ciImage: loadedCI,
                    sequenceIndex: idx + 1
                )
                p.creationDate = phAsset.creationDate
                results.append(p)
            }
        }
        return results
    }

    public static func executeImportToPhotos(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) async throws -> [RoutedAsset] {
        if context.isPreview { return [RoutedAsset(asset: asset)] }
        let albumName = (node.parameters["albumName"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let level: PHAccessLevel = albumName.isEmpty ? .addOnly : .readWrite
        let status = await resolvePhotosAuthorization(for: level, override: context.photosAuthorizationOverride)
        guard status == .authorized || status == .limited else {
            throw NodeExecutionError.authorizationDenied(
                "Photos write access denied. Open System Settings -> Privacy & Security -> Photos."
            )
        }
        guard let img = asset.ciImage else { return [RoutedAsset(asset: asset)] }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("fb_photos_\(UUID().uuidString).jpg")
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try context.exportContext.writeJPEGRepresentation(of: img, to: tempURL, colorSpace: cs, options: [:])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await PHPhotoLibrary.shared().performChanges {
            let createReq = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempURL)
            if !albumName.isEmpty, let placeholder = createReq?.placeholderForCreatedAsset {
                let colFetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                var targetAlbum: PHAssetCollection?
                colFetch.enumerateObjects { col, _, stop in
                    if col.localizedTitle == albumName {
                        targetAlbum = col
                        stop.pointee = true
                    }
                }
                if let targetAlbum, let addReq = PHAssetCollectionChangeRequest(for: targetAlbum) {
                    addReq.addAssets([placeholder] as NSArray)
                } else {
                    let createAlbum = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    createAlbum.addAssets([placeholder] as NSArray)
                }
            }
        }
        return [RoutedAsset(asset: asset)]
    }

    // MARK: - Sandboxed JavaScript Worker, Shell, AppleScript

    private struct JSWorkerReq: Encodable {
        let code: String
        let asset: AssetDTO
        struct AssetDTO: Encodable {
            let fileName: String
            let fileExtension: String
            let width: Double
            let height: Double
            let dpi: Int
            let metadata: [String: String]
            let tags: [String]
        }
    }

    private struct JSWorkerResp: Decodable {
        let skip: Bool
        let outputNameOverride: String?
        let metadata: [String: String]
        let logs: [String]
        let error: String?
    }

    public static func locateJSWorker(overrideURL: URL? = nil) -> URL? {
        if let overrideURL, FileManager.default.isExecutableFile(atPath: overrideURL.path) {
            return overrideURL
        }
        let fm = FileManager.default
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "FlowBatchJSWorker"), fm.isExecutableFile(atPath: aux.path) {
            return aux
        }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FlowBatchJSWorker")
        if fm.isExecutableFile(atPath: helpers.path) {
            return helpers
        }
        let sibling = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("FlowBatchJSWorker")
        if fm.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        for rel in [
            ".build/debug/FlowBatchJSWorker",
            ".build/release/FlowBatchJSWorker",
            ".build/out/Products/Debug/FlowBatchJSWorker",
            ".build/out/Products/Release/FlowBatchJSWorker",
            ".build/arm64-apple-macosx/debug/FlowBatchJSWorker",
            ".build/arm64-apple-macosx/release/FlowBatchJSWorker"
        ] {
            let candidate = cwd.appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func runSandboxedJavaScript(asset: PipelineAsset, node: WorkflowNode, context: NodeExecutionContext) throws {
        guard let workerURL = locateJSWorker(overrideURL: context.jsWorkerURL) else {
            throw NodeExecutionError.scriptFailed("FlowBatchJSWorker helper executable not found.")
        }
        let code = node.parameters["code"]?.stringValue ?? ""
        var stringMeta: [String: String] = asset.customVariables
        if let tiff = asset.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let artist = tiff[kCGImagePropertyTIFFArtist as String] as? String {
            stringMeta["Author"] = artist
        }

        let req = JSWorkerReq(
            code: code,
            asset: .init(
                fileName: asset.fileName,
                fileExtension: asset.fileExtension,
                width: Double(asset.pixelSize.width),
                height: Double(asset.pixelSize.height),
                dpi: asset.dpi,
                metadata: stringMeta,
                tags: asset.classificationLabels.map(\.identifier)
            )
        )
        let reqData = try JSONEncoder().encode(req)

        let process = Process()
        process.executableURL = workerURL
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        stdinPipe.fileHandleForWriting.write(reqData)
        try stdinPipe.fileHandleForWriting.close()

        let timeoutSeconds = 2.0
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }

        let waitResult = sem.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            throw NodeExecutionError.scriptTimedOut(seconds: timeoutSeconds)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let resp = try JSONDecoder().decode(JSWorkerResp.self, from: outData)
        for line in resp.logs {
            context.log(node, level: .info, "[JS] \(line)")
        }
        if let err = resp.error {
            throw NodeExecutionError.scriptFailed(err)
        }
        if resp.skip { asset.shouldSkip = true }
        if let name = resp.outputNameOverride, !name.isEmpty {
            asset.outputNameOverride = name
        }
        for (k, v) in resp.metadata {
            asset.customVariables[k] = v
        }
    }

    private static func runShellScript(asset: PipelineAsset, node: WorkflowNode, context: NodeExecutionContext) throws {
        let script = node.parameters["script"]?.stringValue ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent("fb_shell_\(UUID().uuidString).png")
        if let img = asset.ciImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            try context.exportContext.writePNGRepresentation(of: img, to: stagedURL, format: .RGBA8, colorSpace: cs, options: [:])
        }
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script, "flowbatch", stagedURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !outStr.isEmpty { context.log(node, level: .info, outStr.trimmingCharacters(in: .newlines)) }
        if process.terminationStatus != 0 {
            throw NodeExecutionError.scriptFailed(errStr.isEmpty ? "Exit code \(process.terminationStatus)" : errStr)
        }
        if FileManager.default.fileExists(atPath: stagedURL.path),
           let updated = CIImage(contentsOf: stagedURL, options: [.applyOrientationProperty: true]) {
            asset.ciImage = updated
        }
    }

    private static func runAppleScript(asset: PipelineAsset, node: WorkflowNode, context: NodeExecutionContext) throws {
        let source = node.parameters["script"]?.stringValue ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var scriptErr: NSDictionary?
        let appleScript = NSAppleScript(source: source)
        let result = appleScript?.executeAndReturnError(&scriptErr)
        if let scriptErr {
            throw NodeExecutionError.scriptFailed(scriptErr.description)
        }
        if let str = result?.stringValue, !str.isEmpty {
            context.log(node, level: .info, "[AppleScript] \(str)")
        }
    }
}
