import CoreGraphics
import CoreImage
import Foundation

/// Implements Blur, Sharpen, Color Adjustment, and Color Effect nodes cleanly via Core Image
/// (with CPU Floyd-Steinberg 1-bit quantization inside `autoreleasepool`).
public enum ColorFilterExecutors {
    public static func execute(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws -> [RoutedAsset] {
        guard let input = asset.ciImage else { return [RoutedAsset(asset: asset)] }
        let originalExtent = input.extent
        var output: CIImage = input

        switch node.typeID {
        // MARK: - Blur
        case NodeTypeID.gaussianBlur:
            let radius = node.parameters["radius"]?.doubleValue ?? 10
            output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: originalExtent)

        case NodeTypeID.boxBlur:
            let radius = max(1, node.parameters["radius"]?.doubleValue ?? 10)
            output = input.clampedToExtent()
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: originalExtent)

        case NodeTypeID.motionBlur:
            let radius = node.parameters["radius"]?.doubleValue ?? 20
            let angleRad = (node.parameters["angle"]?.doubleValue ?? 0) * .pi / 180.0
            output = input.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angleRad])
                .cropped(to: originalExtent)

        case NodeTypeID.noiseReduction:
            let level = node.parameters["noiseLevel"]?.doubleValue ?? 0.02
            let sharp = node.parameters["sharpness"]?.doubleValue ?? 0.4
            output = input.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": level,
                "inputSharpness": sharp
            ])

        case NodeTypeID.pixelate:
            let scale = max(1, node.parameters["scale"]?.doubleValue ?? 12)
            output = input.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
                .cropped(to: originalExtent)

        // MARK: - Sharpen
        case NodeTypeID.sharpenLuminance:
            let sharpness = node.parameters["sharpness"]?.doubleValue ?? 0.6
            let radius = node.parameters["radius"]?.doubleValue ?? 1.69
            output = input.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: sharpness,
                kCIInputRadiusKey: radius
            ])

        case NodeTypeID.unsharpMask:
            let radius = node.parameters["radius"]?.doubleValue ?? 2.5
            let intensity = node.parameters["intensity"]?.doubleValue ?? 0.75
            output = input.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: radius,
                kCIInputIntensityKey: intensity
            ])

        // MARK: - Color Adjustment
        case NodeTypeID.exposure:
            let ev = node.parameters["ev"]?.doubleValue ?? 0.5
            output = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])

        case NodeTypeID.brightnessContrast:
            let b = node.parameters["brightness"]?.doubleValue ?? 0
            let c = node.parameters["contrast"]?.doubleValue ?? 1
            let s = node.parameters["saturation"]?.doubleValue ?? 1
            output = input.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: b,
                kCIInputContrastKey: c,
                kCIInputSaturationKey: s
            ])

        case NodeTypeID.vibrance:
            let amount = node.parameters["amount"]?.doubleValue ?? 0.35
            output = input.applyingFilter("CIVibrance", parameters: ["inputAmount": amount])

        case NodeTypeID.gamma:
            let power = node.parameters["power"]?.doubleValue ?? 1.0
            output = input.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])

        case NodeTypeID.temperatureTint:
            let temp = node.parameters["temperature"]?.doubleValue ?? 6500
            let tint = node.parameters["tint"]?.doubleValue ?? 0
            output = input.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: temp, y: tint)
            ])

        case NodeTypeID.shadowsHighlights:
            let sh = node.parameters["shadowAmount"]?.doubleValue ?? 0.25
            let hi = node.parameters["highlightAmount"]?.doubleValue ?? 1.0
            output = input.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": sh,
                "inputHighlightAmount": hi
            ])

        case NodeTypeID.colorProfile:
            let profile = node.parameters["profile"]?.stringValue ?? "sRGB"
            if let cs = colorSpace(named: profile) {
                asset.targetColorSpace = cs
                if let matched = input.matchedFromWorkingSpace(to: cs) {
                    output = matched
                }
            }

        // MARK: - Color Effect
        case NodeTypeID.photoEffect:
            let style = node.parameters["style"]?.stringValue ?? "Noir"
            let filterName = "CIPhotoEffect\(style)"
            output = input.applyingFilter(filterName)

        case NodeTypeID.sepia:
            let intensity = node.parameters["intensity"]?.doubleValue ?? 0.8
            output = input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: intensity])

        case NodeTypeID.colorInvert:
            output = input.applyingFilter("CIColorInvert")

        case NodeTypeID.colorPosterize:
            let levels = max(2, node.parameters["levels"]?.intValue ?? 6)
            output = input.applyingFilter("CIColorPosterize", parameters: ["inputLevels": Double(levels)])

        case NodeTypeID.oneBit:
            let threshold = node.parameters["threshold"]?.doubleValue ?? 0.5
            let dither = node.parameters["dither"]?.boolValue ?? true
            output = try applyOneBit(input, threshold: threshold, dither: dither, context: context.activeCIContext)

        case NodeTypeID.dither:
            let intensity = node.parameters["intensity"]?.doubleValue ?? 0.5
            output = input.applyingFilter("CIDither", parameters: [kCIInputIntensityKey: intensity])

        case NodeTypeID.matte:
            let c = node.parameters["color"]?.colorValue ?? .white
            let bg = CIImage(color: CIColor(cgColor: c.cgColor)).cropped(to: originalExtent)
            output = input.composited(over: bg)

        case NodeTypeID.addBorder:
            let w = CGFloat(max(0, node.parameters["width"]?.intValue ?? 20))
            let c = node.parameters["color"]?.colorValue ?? .white
            let expanded = CGRect(x: 0, y: 0, width: originalExtent.width + w * 2, height: originalExtent.height + w * 2)
            let bg = CIImage(color: CIColor(cgColor: c.cgColor)).cropped(to: expanded)
            let shifted = input.transformed(by: CGAffineTransform(translationX: w, y: w))
            output = shifted.composited(over: bg)

        case NodeTypeID.dropShadow:
            output = applyDropShadow(input, node: node)

        case NodeTypeID.documentEnhancer:
            output = input.applyingFilter("CIDocumentEnhancer")

        default:
            break
        }

        asset.ciImage = normalizeOrigin(output)
        return [RoutedAsset(asset: asset)]
    }

    private static func normalizeOrigin(_ img: CIImage) -> CIImage {
        let ext = img.extent
        guard !ext.isInfinite, ext.origin != .zero else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
    }

    private static func applyDropShadow(_ input: CIImage, node: WorkflowNode) -> CIImage {
        let radius = CGFloat(max(0, node.parameters["radius"]?.doubleValue ?? 16))
        let offX = CGFloat(node.parameters["offsetX"]?.doubleValue ?? 0)
        let offY = CGFloat(node.parameters["offsetY"]?.doubleValue ?? 10)
        let opacity = CGFloat(node.parameters["opacity"]?.doubleValue ?? 0.45)
        let shadowColor = node.parameters["color"]?.colorValue ?? .black

        let pad = ceil(radius * 2.5 + max(abs(offX), abs(offY)))
        let ext = input.extent
        let fullRect = CGRect(x: -pad, y: -pad, width: ext.width + pad * 2, height: ext.height + pad * 2)

        // Extract alpha mask tinted to shadow color, blur, offset, and composite original on top
        let tintMatrix = CIFilter(name: "CIColorMatrix")!
        tintMatrix.setValue(input, forKey: kCIInputImageKey)
        tintMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        tintMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        tintMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        tintMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: opacity * shadowColor.alpha), forKey: "inputAVector")
        tintMatrix.setValue(CIVector(x: shadowColor.red, y: shadowColor.green, z: shadowColor.blue, w: 0), forKey: "inputBiasVector")

        let silhouette = tintMatrix.outputImage ?? input
        let blurred = silhouette
            .clamped(to: fullRect)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .transformed(by: CGAffineTransform(translationX: offX, y: -offY))
            .cropped(to: fullRect)

        return input.composited(over: blurred).cropped(to: fullRect)
    }

    private static func applyOneBit(_ input: CIImage, threshold: Double, dither: Bool, context: CIContext) throws -> CIImage {
        let extent = input.extent.integral
        let w = Int(extent.width)
        let h = Int(extent.height)
        guard w > 0, h > 0 else { return input }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            context.render(input, toBitmap: base, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: srgb)
        }

        var luma = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            luma[i] = (0.299 * Double(rgba[o]) + 0.587 * Double(rgba[o + 1]) + 0.114 * Double(rgba[o + 2])) / 255.0
        }

        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let old = luma[idx]
                let newVal: Double = old >= threshold ? 1.0 : 0.0
                let byteVal: UInt8 = newVal > 0.5 ? 255 : 0
                let o = idx * 4
                rgba[o] = byteVal
                rgba[o + 1] = byteVal
                rgba[o + 2] = byteVal
                if dither {
                    let err = old - newVal
                    if x + 1 < w { luma[idx + 1] += err * 7.0 / 16.0 }
                    if y + 1 < h {
                        if x > 0 { luma[(y + 1) * w + (x - 1)] += err * 3.0 / 16.0 }
                        luma[(y + 1) * w + x] += err * 5.0 / 16.0
                        if x + 1 < w { luma[(y + 1) * w + (x + 1)] += err * 1.0 / 16.0 }
                    }
                }
            }
        }

        let data = Data(rgba)
        return CIImage(bitmapData: data, bytesPerRow: w * 4, size: extent.size, format: .RGBA8, colorSpace: srgb)
    }

    private static func colorSpace(named name: String) -> CGColorSpace? {
        switch name {
        case "Display P3": return CGColorSpace(name: CGColorSpace.displayP3)
        case "Adobe RGB (1998)": return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case "Generic Gray": return CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        case "Generic CMYK": return CGColorSpace(name: CGColorSpace.genericCMYK)
        default: return CGColorSpace(name: CGColorSpace.sRGB)
        }
    }
}
