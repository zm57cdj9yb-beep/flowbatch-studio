import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum ReadWriteExecutors {
    // MARK: - Source Ingestion

    public static func executeSource(
        node: WorkflowNode,
        context: NodeExecutionContext
    ) async throws -> [PipelineAsset] {
        switch node.typeID {
        case NodeTypeID.readFolder:
            let path = node.parameters["folderPath"]?.stringValue ?? ""
            guard !path.isEmpty else {
                throw NodeExecutionError.missingInput("No folder selected for '\(node.title)'.")
            }
            let folderURL = URL(fileURLWithPath: path, isDirectory: true)
            let recursive = node.parameters["includeSubfolders"]?.boolValue ?? false
            let extRaw = node.parameters["filterExtensions"]?.stringValue ?? ""
            let customExts = Set(
                extRaw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            let allowed = customExts.isEmpty ? DryRunEstimator.supportedImageExtensions : customExts
            let urls = DryRunEstimator.listImageURLs(in: folderURL, recursive: recursive, allowedExtensions: allowed)
            var results: [PipelineAsset] = []
            results.reserveCapacity(urls.count)
            for (idx, url) in urls.enumerated() {
                try Task.checkCancellation()
                let asset = try PipelineAsset.load(
                    from: url,
                    sequenceIndex: idx + 1,
                    rawScaleFactor: context.rawScaleFactor,
                    subsampleFactor: context.subsampleFactor
                )
                results.append(asset)
            }
            return results

        case NodeTypeID.readFiles:
            let raw = node.parameters["filePaths"]?.stringValue ?? ""
            let urls = raw.split(separator: ";")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            var results: [PipelineAsset] = []
            for (idx, url) in urls.enumerated() {
                try Task.checkCancellation()
                results.append(try PipelineAsset.load(
                    from: url,
                    sequenceIndex: idx + 1,
                    rawScaleFactor: context.rawScaleFactor,
                    subsampleFactor: context.subsampleFactor
                ))
            }
            return results

        case NodeTypeID.promptForFiles:
            if context.isPreview { return [] }
            let allowMulti = node.parameters["allowMultiple"]?.boolValue ?? true
            guard let urls = await context.promptService.chooseFiles(allowMultiple: allowMulti) else {
                throw NodeExecutionError.userCancelled
            }
            var results: [PipelineAsset] = []
            for (idx, url) in urls.enumerated() {
                try Task.checkCancellation()
                results.append(try PipelineAsset.load(
                    from: url,
                    sequenceIndex: idx + 1,
                    rawScaleFactor: context.rawScaleFactor,
                    subsampleFactor: context.subsampleFactor
                ))
            }
            return results

        case NodeTypeID.readClipboard:
            var loaded: CIImage?
            let pbName = context.pasteboardName
            await MainActor.run {
                let pb = pbName.map { NSPasteboard(name: $0) } ?? NSPasteboard.general
                if let tiff = pb.data(forType: .tiff), let ci = CIImage(data: tiff) {
                    loaded = ci
                } else if let png = pb.data(forType: .png), let ci = CIImage(data: png) {
                    loaded = ci
                } else if let img = NSImage(pasteboard: pb), let tiffData = img.tiffRepresentation {
                    loaded = CIImage(data: tiffData)
                }
            }
            guard let loaded else {
                throw NodeExecutionError.missingInput("No image found on the clipboard.")
            }
            return [PipelineAsset(fileName: "Clipboard", fileExtension: "png", ciImage: loaded)]

        default:
            return []
        }
    }

    // MARK: - RAW Process

    public static func executeRAWProcess(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws -> [RoutedAsset] {
        guard let url = asset.sourceURL else {
            return [RoutedAsset(asset: asset)]
        }
        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            if asset.ciImage == nil || asset.ciImage?.extent.isEmpty == true {
                throw NodeExecutionError.invalidParameter("Unable to decode RAW file '\(url.lastPathComponent)'.")
            }
            return [RoutedAsset(asset: asset)]
        }
        rawFilter.scaleFactor = max(0.05, min(1.0, context.rawScaleFactor))
        rawFilter.exposure = Float(node.parameters["exposure"]?.doubleValue ?? 0)
        rawFilter.neutralTemperature = Float(node.parameters["temperature"]?.doubleValue ?? 6500)
        rawFilter.neutralTint = Float(node.parameters["tint"]?.doubleValue ?? 0)
        rawFilter.luminanceNoiseReductionAmount = Float(node.parameters["luminanceNoiseReduction"]?.doubleValue ?? 0.25)
        rawFilter.isDraftModeEnabled = node.parameters["draftMode"]?.boolValue ?? false

        if let out = rawFilter.outputImage, !out.extent.isEmpty {
            asset.ciImage = out
        } else if asset.ciImage == nil || asset.ciImage?.extent.isEmpty == true {
            throw NodeExecutionError.invalidParameter("Unable to decode RAW file '\(url.lastPathComponent)'.")
        }
        return [RoutedAsset(asset: asset)]
    }

    // MARK: - Multi Scale

    public static func executeMultiScale(
        asset: PipelineAsset,
        node: WorkflowNode
    ) -> [RoutedAsset] {
        let specs = node.parameters["scales"]?.scalesValue ?? [
            ScaleBranchSpec(label: "1x", scaleFactor: 0.5, suffix: ""),
            ScaleBranchSpec(label: "2x", scaleFactor: 1.0, suffix: "@2x")
        ]
        var outputs: [RoutedAsset] = []
        for spec in specs where spec.scaleFactor > 0 {
            let copy = asset.deepCopy()
            if let img = copy.ciImage, abs(spec.scaleFactor - 1.0) > 0.0001 {
                let scaleFilter = CIFilter(name: "CILanczosScaleTransform")
                scaleFilter?.setValue(img, forKey: kCIInputImageKey)
                scaleFilter?.setValue(spec.scaleFactor, forKey: kCIInputScaleKey)
                scaleFilter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let scaled = scaleFilter?.outputImage {
                    copy.ciImage = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
                }
            }
            let base = copy.outputNameOverride ?? copy.fileName
            copy.outputNameOverride = base + spec.suffix
            outputs.append(RoutedAsset(asset: copy))
        }
        return outputs
    }

    // MARK: - Write Images / Clipboard / Open In App

    public static func resolveOutputDirectory(
        for node: WorkflowNode,
        context: NodeExecutionContext
    ) async throws -> URL? {
        guard node.typeID == NodeTypeID.writeImages else { return nil }
        if node.parameters["writeBackToOriginal"]?.boolValue == true {
            return nil
        }
        if node.parameters["askForOutputFolder"]?.boolValue == true {
            guard let chosen = await context.promptService.chooseOutputFolder(promptTitle: "Choose Output Folder for \(node.title)") else {
                throw NodeExecutionError.userCancelled
            }
            return chosen
        }
        let folderPath = node.parameters["folderPath"]?.stringValue ?? ""
        guard !folderPath.isEmpty else {
            throw NodeExecutionError.invalidParameter("No output folder configured for '\(node.title)'.")
        }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    public static func executeWriteImages(
        asset: PipelineAsset,
        node: WorkflowNode,
        resolvedOutputFolder: URL?,
        context: NodeExecutionContext
    ) throws -> [RoutedAsset] {
        // In live preview mode, never write files to disk!
        if context.isPreview {
            return [RoutedAsset(asset: asset)]
        }

        let writeBack = node.parameters["writeBackToOriginal"]?.boolValue ?? false
        let overwrite = node.parameters["overwriteExisting"]?.boolValue ?? true
        let readBack = node.parameters["readBackEncoded"]?.boolValue ?? false
        let keepDates = node.parameters["keepOriginalDates"]?.boolValue ?? false
        let pattern = node.parameters["fileNamePattern"]?.stringValue ?? "[File Name]"
        let rawFormat = node.parameters["format"]?.stringValue ?? "PNG"
        let quality = node.parameters["quality"]?.doubleValue ?? 0.88
        let removeAlphaIfOpaque = node.parameters["removeAlphaIfOpaque"]?.boolValue ?? true
        let crushPNG = node.parameters["crushPNG"]?.boolValue ?? false
        let bruteForce = node.parameters["bruteForceCrushPNG"]?.boolValue ?? false
        let removeColorProfile = node.parameters["removeColorProfile"]?.boolValue ?? false
        let makeIndexed = node.parameters["makeIndexedPNG"]?.boolValue ?? false
        let indexedColors = node.parameters["indexedColors"]?.intValue ?? 256
        let indexedSpeed = node.parameters["indexedSpeed"]?.intValue ?? 1
        let indexedDither = node.parameters["indexedDither"]?.boolValue ?? false

        let targetFormat = rawFormat == "Original" ? formatName(fromExtension: asset.fileExtension) : rawFormat
        let targetExt = fileExtension(forFormat: targetFormat, originalExt: asset.fileExtension)

        let baseName = TokenExpander.expand(pattern, for: asset).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBaseName = (baseName.isEmpty ? asset.fileName : baseName).replacingOccurrences(of: "/", with: "-")

        let outputURL: URL
        if writeBack, let src = asset.sourceURL {
            outputURL = src.deletingPathExtension().appendingPathExtension(targetExt)
        } else {
            guard let folder = resolvedOutputFolder else {
                throw NodeExecutionError.invalidParameter("No output folder selected.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let initial = folder.appendingPathComponent(safeBaseName).appendingPathExtension(targetExt)
            outputURL = overwrite ? initial : uniqueNonOverwritingURL(for: initial)
        }

        try autoreleasepool {
            // Special passthroughs: prebuilt multi-page PDF or multi-frame GIF
            if let pdfData = asset.pdfData, targetFormat == "PDF" {
                try pdfData.write(to: outputURL, options: .atomic)
            } else if let frames = asset.animatedFrames, !frames.isEmpty, targetFormat == "GIF" {
                try writeAnimatedGIF(frames: frames, to: outputURL, context: context.exportContext)
            } else {
                guard let image = asset.ciImage else {
                    throw NodeExecutionError.missingInput("Asset '\(asset.fileName)' has no renderable image.")
                }

                let targetCS = removeColorProfile
                    ? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
                    : (asset.targetColorSpace ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

                if targetFormat == "PNG" && makeIndexed {
                    let pngData = try IndexedPNGQuantizer.encode(
                        image: image,
                        context: context.exportContext,
                        options: IndexedPNGOptions(
                            maxColors: indexedColors,
                            speed: indexedSpeed,
                            dither: indexedDither,
                            removeAlphaIfOpaque: removeAlphaIfOpaque,
                            removeColorProfile: removeColorProfile,
                            crush: crushPNG,
                            bruteForceCrush: bruteForce
                        )
                    )
                    try pngData.write(to: outputURL, options: .atomic)
                } else if targetFormat == "PDF" {
                    try writeSinglePagePDF(image: image, to: outputURL, context: context.exportContext, colorSpace: targetCS)
                } else {
                    try writeStandardImage(
                        image: image,
                        asset: asset,
                        format: targetFormat,
                        quality: quality,
                        removeColorProfile: removeColorProfile,
                        colorSpace: targetCS,
                        to: outputURL,
                        context: context.exportContext
                    )
                }
            }

            if keepDates {
                var attrs: [FileAttributeKey: Any] = [:]
                if let c = asset.creationDate { attrs[.creationDate] = c }
                if let m = asset.modificationDate { attrs[.modificationDate] = m }
                if !attrs.isEmpty {
                    try? FileManager.default.setAttributes(attrs, ofItemAtPath: outputURL.path)
                }
            }
        }

        asset.writtenOutputURL = outputURL

        if readBack {
            let reloaded = try PipelineAsset.load(from: outputURL, sequenceIndex: asset.sequenceIndex)
            return [RoutedAsset(asset: reloaded)]
        }

        return [RoutedAsset(asset: asset)]
    }

    public static func executeWriteClipboard(asset: PipelineAsset, context: NodeExecutionContext) async throws -> [RoutedAsset] {
        if context.isPreview { return [RoutedAsset(asset: asset)] }
        guard let img = asset.ciImage else {
            throw NodeExecutionError.missingInput("Asset '\(asset.fileName)' has no renderable image for clipboard.")
        }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = context.exportContext.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: cs) else {
            throw NodeExecutionError.encodingFailed("Could not rasterize image for clipboard.")
        }
        let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pbName = context.pasteboardName
        await MainActor.run {
            let pb = pbName.map { NSPasteboard(name: $0) } ?? NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImg])
        }
        return [RoutedAsset(asset: asset)]
    }

    public static func executeOpenInApp(asset: PipelineAsset, node: WorkflowNode, context: NodeExecutionContext) throws -> [RoutedAsset] {
        if context.isPreview { return [RoutedAsset(asset: asset)] }
        let appPath = node.parameters["applicationPath"]?.stringValue ?? "/System/Applications/Preview.app"
        guard !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) else {
            throw NodeExecutionError.invalidParameter("Target application not found: \(appPath)")
        }
        guard let img = asset.ciImage else {
            throw NodeExecutionError.missingInput("Asset '\(asset.fileName)' has no renderable image.")
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FlowBatchOpen", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent(asset.outputNameOverride ?? asset.fileName).appendingPathExtension("png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try context.exportContext.writePNGRepresentation(of: img, to: targetURL, format: .RGBA8, colorSpace: cs, options: [:])
        let appURL = URL(fileURLWithPath: appPath)
        NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return [RoutedAsset(asset: asset)]
    }

    // MARK: - Format Helpers

    private static func writeStandardImage(
        image: CIImage,
        asset: PipelineAsset,
        format: String,
        quality: Double,
        removeColorProfile: Bool,
        colorSpace: CGColorSpace,
        to url: URL,
        context: CIContext
    ) throws {
        let hasCustomMetadata = asset.metadata[kCGImagePropertyTIFFDictionary as String] != nil
            || asset.metadata[kCGImagePropertyExifDictionary as String] != nil
            || asset.metadata[kCGImagePropertyIPTCDictionary as String] != nil
            || asset.dpi != 72

        // Fast streaming zero-CGImage path when using CIContext direct encoders
        if !hasCustomMetadata && !removeColorProfile {
            switch format {
            case "JPEG":
                try context.writeJPEGRepresentation(
                    of: image,
                    to: url,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                )
                return
            case "HEIC":
                try context.writeHEIFRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA8,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                )
                return
            case "PNG":
                try context.writePNGRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA8,
                    colorSpace: colorSpace,
                    options: [:]
                )
                return
            default:
                break
            }
        }

        let utTypeIdentifier = utiIdentifier(forFormat: format)
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard supported.contains(utTypeIdentifier) else {
            throw NodeExecutionError.encodingFailed("Format '\(format)' (\(utTypeIdentifier)) is not supported by ImageIO on this system.")
        }

        let ciFormat: CIFormat = asset.bitsPerChannel >= 16 ? .RGBA16 : .RGBA8
        guard let cgImage = context.createCGImage(image, from: image.extent, format: ciFormat, colorSpace: colorSpace) else {
            throw NodeExecutionError.encodingFailed("Failed to materialize CGImage for \(format).")
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utTypeIdentifier as CFString, 1, nil) else {
            throw NodeExecutionError.encodingFailed("Failed to create image destination for \(url.lastPathComponent).")
        }

        var props = asset.metadata
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        props[kCGImagePropertyDPIWidth as String] = asset.dpi
        props[kCGImagePropertyDPIHeight as String] = asset.dpi
        if removeColorProfile {
            props.removeValue(forKey: kCGImagePropertyProfileName as String)
        }

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NodeExecutionError.encodingFailed("ImageIO failed writing \(url.lastPathComponent).")
        }
    }

    private static func writeSinglePagePDF(image: CIImage, to url: URL, context: CIContext, colorSpace: CGColorSpace) throws {
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw NodeExecutionError.encodingFailed("Failed to create CGImage for PDF.")
        }
        let pdfDoc = PDFDocument()
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if let page = PDFPage(image: nsImage) {
            pdfDoc.insert(page, at: 0)
        }
        guard pdfDoc.write(to: url) else {
            throw NodeExecutionError.encodingFailed("Failed to write PDF to \(url.lastPathComponent).")
        }
    }

    private static func writeAnimatedGIF(frames: [(image: CIImage, delay: Double)], to url: URL, context: CIContext) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw NodeExecutionError.encodingFailed("Failed to initialize GIF destination.")
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        for frame in frames {
            if let cg = context.createCGImage(frame.image, from: frame.image.extent, format: .RGBA8, colorSpace: cs) {
                let frameProps: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay]
                ]
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NodeExecutionError.encodingFailed("Failed to finalize animated GIF.")
        }
    }

    private static func utiIdentifier(forFormat format: String) -> String {
        switch format {
        case "JPEG": return UTType.jpeg.identifier
        case "PNG": return UTType.png.identifier
        case "HEIC": return UTType.heic.identifier
        case "AVIF": return "public.avif"
        case "TIFF": return UTType.tiff.identifier
        case "GIF": return UTType.gif.identifier
        case "JPEG 2000": return "public.jpeg-2000"
        case "BMP": return UTType.bmp.identifier
        case "PDF": return UTType.pdf.identifier
        case "PSD": return "com.adobe.photoshop-image"
        default: return UTType.png.identifier
        }
    }

    private static func formatName(fromExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "avif": return "AVIF"
        case "tif", "tiff": return "TIFF"
        case "gif": return "GIF"
        case "jp2", "j2k": return "JPEG 2000"
        case "bmp": return "BMP"
        case "pdf": return "PDF"
        case "psd": return "PSD"
        default: return "PNG"
        }
    }

    private static func fileExtension(forFormat format: String, originalExt: String) -> String {
        switch format {
        case "JPEG": return "jpg"
        case "PNG": return "png"
        case "HEIC": return "heic"
        case "AVIF": return "avif"
        case "TIFF": return "tiff"
        case "GIF": return "gif"
        case "JPEG 2000": return "jp2"
        case "BMP": return "bmp"
        case "PDF": return "pdf"
        case "PSD": return "psd"
        default: return originalExt.isEmpty ? "png" : originalExt
        }
    }

    private static func uniqueNonOverwritingURL(for url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 1...9999 {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return url
    }
}
