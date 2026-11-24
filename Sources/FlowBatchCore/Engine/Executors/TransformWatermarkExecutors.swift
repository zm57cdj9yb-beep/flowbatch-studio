import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Implements Transform (`Scale`, `Crop`, `Rotate`, `Flip`, `Trim to Edges`, `ML Super Resolution`)
/// and Watermark (`Text Watermark`, `Image Watermark`) nodes.
public enum TransformWatermarkExecutors {
    public static func execute(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws -> [RoutedAsset] {
        guard let input = asset.ciImage else { return [RoutedAsset(asset: asset)] }
        var output = input

        switch node.typeID {
        case NodeTypeID.scale:
            output = applyScale(input, node: node)

        case NodeTypeID.crop:
            output = applyCrop(input, node: node)

        case NodeTypeID.rotate:
            let degrees = node.parameters["degrees"]?.doubleValue ?? 90
            let rad = CGFloat(-degrees * .pi / 180.0)
            let rotated = input.transformed(by: CGAffineTransform(rotationAngle: rad))
            let bgColor = node.parameters["backgroundColor"]?.colorValue ?? .clear
            if bgColor.alpha > 0.001 {
                let bg = CIImage(color: CIColor(cgColor: bgColor.cgColor)).cropped(to: rotated.extent)
                output = rotated.composited(over: bg)
            } else {
                output = rotated
            }

        case NodeTypeID.flip:
            let dir = node.parameters["direction"]?.stringValue ?? "Horizontal"
            let ext = input.extent
            var t = CGAffineTransform.identity
            if dir == "Horizontal" || dir == "Both" {
                t = t.translatedBy(x: ext.width, y: 0).scaledBy(x: -1, y: 1)
            }
            if dir == "Vertical" || dir == "Both" {
                t = t.translatedBy(x: 0, y: ext.height).scaledBy(x: 1, y: -1)
            }
            output = input.transformed(by: t)

        case NodeTypeID.trimToEdges:
            let threshold = node.parameters["alphaThreshold"]?.doubleValue ?? 0.02
            output = trimTransparentEdges(input, threshold: threshold, context: context.activeCIContext)

        case NodeTypeID.mlSuperResolution:
            let multStr = node.parameters["multiplier"]?.stringValue ?? "2x"
            let scale = multStr == "4x" ? 4.0 : 2.0
            let edgeSharpen = node.parameters["edgeSharpen"]?.doubleValue ?? 0.45
            let scaled = lanczosScale(input, scaleX: scale, scaleY: scale)
            output = scaled.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: edgeSharpen,
                kCIInputRadiusKey: 1.2
            ])

        case NodeTypeID.textWatermark:
            output = applyTextWatermark(input, asset: asset, node: node)

        case NodeTypeID.imageWatermark:
            output = applyImageWatermark(input, node: node)

        default:
            break
        }

        asset.ciImage = normalizeOrigin(output)
        return [RoutedAsset(asset: asset)]
    }

    // MARK: - Scale & Crop

    private static func lanczosScale(_ image: CIImage, scaleX: Double, scaleY: Double) -> CIImage {
        guard scaleX > 0, scaleY > 0 else { return image }
        let aspect = scaleX / scaleY
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(scaleY, forKey: kCIInputScaleKey)
        filter?.setValue(aspect, forKey: kCIInputAspectRatioKey)
        return filter?.outputImage ?? image
    }

    private static func applyScale(_ image: CIImage, node: WorkflowNode) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }

        let mode = node.parameters["mode"]?.stringValue ?? "Fixed Width"
        let targetW = Double(max(1, node.parameters["width"]?.intValue ?? 800))
        let targetH = Double(max(1, node.parameters["height"]?.intValue ?? 600))
        let percent = max(1.0, node.parameters["percent"]?.doubleValue ?? 50.0)
        let allowUpscale = node.parameters["allowUpscale"]?.boolValue ?? true

        var sx = 1.0
        var sy = 1.0

        switch mode {
        case "Fixed Width":
            let s = targetW / Double(ext.width)
            sx = s; sy = s
        case "Fixed Height":
            let s = targetH / Double(ext.height)
            sx = s; sy = s
        case "Percentage":
            let s = percent / 100.0
            sx = s; sy = s
        case "Fit Inside":
            let s = min(targetW / Double(ext.width), targetH / Double(ext.height))
            sx = s; sy = s
        case "Exact Size":
            sx = targetW / Double(ext.width)
            sy = targetH / Double(ext.height)
        default:
            let s = targetW / Double(ext.width)
            sx = s; sy = s
        }

        if !allowUpscale {
            sx = min(1.0, sx)
            sy = min(1.0, sy)
        }

        if abs(sx - 1.0) < 0.0001 && abs(sy - 1.0) < 0.0001 {
            return image
        }
        return lanczosScale(image, scaleX: sx, scaleY: sy)
    }

    private static func applyCrop(_ image: CIImage, node: WorkflowNode) -> CIImage {
        let ext = image.extent
        let mode = node.parameters["mode"]?.stringValue ?? "Aspect Ratio"
        let anchor = node.parameters["anchor"]?.stringValue ?? "center"

        var cropW = ext.width
        var cropH = ext.height

        if mode == "Pixels" || mode == "Fixed Size" {
            cropW = min(ext.width, CGFloat(max(1, node.parameters["width"]?.intValue ?? 800)))
            cropH = min(ext.height, CGFloat(max(1, node.parameters["height"]?.intValue ?? 800)))
        } else {
            let ratioStr = node.parameters["aspectRatio"]?.stringValue ?? "1:1"
            let parts = ratioStr.split(separator: ":").compactMap { Double($0) }
            let ratio = (parts.count == 2 && parts[1] > 0) ? parts[0] / parts[1] : 1.0
            let currentRatio = Double(ext.width / ext.height)
            if currentRatio > ratio {
                cropH = ext.height
                cropW = floor(ext.height * CGFloat(ratio))
            } else {
                cropW = ext.width
                cropH = floor(ext.width / CGFloat(ratio))
            }
        }

        let origin = AnchorLayout.origin(
            anchor: anchor,
            canvasSize: ext.size,
            overlaySize: CGSize(width: cropW, height: cropH),
            marginX: 0,
            marginY: 0
        )
        let cropRect = CGRect(x: ext.minX + origin.x, y: ext.minY + origin.y, width: cropW, height: cropH)
        return image.cropped(to: cropRect)
    }

    private static func trimTransparentEdges(_ image: CIImage, threshold: Double, context: CIContext) -> CIImage {
        let ext = image.extent.integral
        let w = Int(ext.width)
        let h = Int(ext.height)
        guard w > 0, h > 0, w * h <= 24_000_000 else { return image }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: w * 4, bounds: ext, format: .RGBA8, colorSpace: srgb)
        }

        let minAlpha = UInt8(max(0, min(255, Int(threshold * 255.0))))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let a = rgba[(y * w + x) * 4 + 3]
                if a > minAlpha {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return image }
        // Core Image Y=0 is bottom; top-down bitmap y=0 corresponds to maxY in CI coordinates
        let ciY = ext.minY + CGFloat(h - 1 - maxY)
        let cropRect = CGRect(
            x: ext.minX + CGFloat(minX),
            y: ciY,
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
        return image.cropped(to: cropRect)
    }

    // MARK: - Watermarks (Thread-Safe CoreText Rendering)

    private static func applyTextWatermark(_ image: CIImage, asset: PipelineAsset, node: WorkflowNode) -> CIImage {
        let rawText = node.parameters["text"]?.stringValue ?? "@ FlowBatch Sample"
        let text = TokenExpander.expand(rawText, for: asset)
        guard !text.isEmpty else { return image }

        let baseFontSize = CGFloat(max(6, node.parameters["fontSize"]?.doubleValue ?? 28))
        let color = node.parameters["color"]?.colorValue ?? .white
        let opacity = CGFloat(max(0.01, min(1.0, node.parameters["opacity"]?.doubleValue ?? 0.75)))
        let anchor = node.parameters["anchor"]?.stringValue ?? "bottomRight"
        let marginX = CGFloat(node.parameters["marginX"]?.intValue ?? 28)
        let marginY = CGFloat(node.parameters["marginY"]?.intValue ?? 24)
        let rotation = CGFloat(node.parameters["rotation"]?.doubleValue ?? 0) * .pi / 180.0
        let tile = node.parameters["tile"]?.boolValue ?? false
        let blendMode = node.parameters["blendMode"]?.stringValue ?? "Normal"

        // Scale font proportionally if working on a preview-subsampled image? Keep extent-relative cleanly
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, baseFontSize, nil)
        let cgTextColor = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue), CGFloat(color.alpha) * opacity]
        )!
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgTextColor
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textW = ceil(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))) + 16
        let textH = ceil(ascent + descent + leading) + 16

        let bw = max(2, Int(textW))
        let bh = max(2, Int(textH))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgCtx = CGContext(
            data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        cgCtx.setShadow(
            offset: CGSize(width: 0, height: -1.5),
            blur: 3.0,
            color: CGColor(gray: 0, alpha: 0.45 * opacity)
        )
        cgCtx.textPosition = CGPoint(x: 8, y: descent + 8)
        CTLineDraw(line, cgCtx)

        guard let textCG = cgCtx.makeImage() else { return image }
        var overlay = CIImage(cgImage: textCG)
        if abs(rotation) > 0.001 {
            let cx = overlay.extent.midX
            let cy = overlay.extent.midY
            let rotTransform = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: rotation)
                .translatedBy(x: -cx, y: -cy)
            overlay = overlay.transformed(by: rotTransform)
            overlay = overlay.transformed(by: CGAffineTransform(translationX: -overlay.extent.origin.x, y: -overlay.extent.origin.y))
        }

        if tile {
            return tileOverlay(overlay, over: image, spacingX: 60, spacingY: 50, blendMode: blendMode)
        }

        let pos = AnchorLayout.origin(
            anchor: anchor,
            canvasSize: image.extent.size,
            overlaySize: overlay.extent.size,
            marginX: marginX,
            marginY: marginY
        )
        let placed = overlay.transformed(by: CGAffineTransform(translationX: image.extent.minX + pos.x, y: image.extent.minY + pos.y))
        return AnchorLayout.composite(overlay: placed, over: image, blendMode: blendMode)
    }

    private static func applyImageWatermark(_ image: CIImage, node: WorkflowNode) -> CIImage {
        let path = node.parameters["imagePath"]?.stringValue ?? ""
        guard !path.isEmpty, let wmCI = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            return image
        }

        let scalePct = max(1, node.parameters["scalePercent"]?.doubleValue ?? 20) / 100.0
        let opacity = max(0.01, min(1.0, node.parameters["opacity"]?.doubleValue ?? 0.8))
        let anchor = node.parameters["anchor"]?.stringValue ?? "bottomRight"
        let marginX = CGFloat(node.parameters["marginX"]?.intValue ?? 24)
        let marginY = CGFloat(node.parameters["marginY"]?.intValue ?? 24)
        let tile = node.parameters["tile"]?.boolValue ?? false
        let blendMode = node.parameters["blendMode"]?.stringValue ?? "Normal"

        let targetW = Double(image.extent.width) * scalePct
        let factor = targetW / max(1.0, Double(wmCI.extent.width))
        var overlay = lanczosScale(wmCI, scaleX: factor, scaleY: factor)

        // Apply opacity via color matrix alpha scale
        let alphaFilter = CIFilter(name: "CIColorMatrix")!
        alphaFilter.setValue(overlay, forKey: kCIInputImageKey)
        alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)), forKey: "inputAVector")
        overlay = alphaFilter.outputImage ?? overlay
        overlay = normalizeOrigin(overlay)

        if tile {
            return tileOverlay(overlay, over: image, spacingX: 48, spacingY: 48, blendMode: blendMode)
        }

        let pos = AnchorLayout.origin(
            anchor: anchor,
            canvasSize: image.extent.size,
            overlaySize: overlay.extent.size,
            marginX: marginX,
            marginY: marginY
        )
        let placed = overlay.transformed(by: CGAffineTransform(translationX: image.extent.minX + pos.x, y: image.extent.minY + pos.y))
        return AnchorLayout.composite(overlay: placed, over: image, blendMode: blendMode)
    }

    private static func tileOverlay(
        _ overlay: CIImage,
        over background: CIImage,
        spacingX: CGFloat,
        spacingY: CGFloat,
        blendMode: String
    ) -> CIImage {
        let cellW = max(20, overlay.extent.width + spacingX)
        let cellH = max(20, overlay.extent.height + spacingY)
        let tileBounds = CGRect(x: 0, y: 0, width: cellW, height: cellH)
        let tileCanvas = overlay.cropped(to: tileBounds)
        let tiled = tileCanvas.applyingFilter("CIAffineTile", parameters: [
            kCIInputTransformKey: NSAffineTransform()
        ]).cropped(to: background.extent)
        return AnchorLayout.composite(overlay: tiled, over: background, blendMode: blendMode)
    }

    private static func normalizeOrigin(_ img: CIImage) -> CIImage {
        let ext = img.extent
        guard !ext.isInfinite, ext.origin != .zero else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
    }
}
