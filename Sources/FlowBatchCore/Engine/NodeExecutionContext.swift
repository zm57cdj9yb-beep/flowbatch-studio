import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Photos

/// Interactive main-thread prompt bridge used by `Prompt for Files` and `Write Images` ("Ask on Run").
public protocol UserPromptService: Sendable {
    @MainActor
    func chooseFiles(allowMultiple: Bool) async -> [URL]?

    @MainActor
    func chooseOutputFolder(promptTitle: String) async -> URL?
}

/// Default headless prompt service returning `nil` (cancelling interactive prompts cleanly in CLI/test contexts).
public struct NoopPromptService: UserPromptService {
    public init() {}
    @MainActor public func chooseFiles(allowMultiple: Bool) async -> [URL]? { nil }
    @MainActor public func chooseOutputFolder(promptTitle: String) async -> URL? { nil }
}

/// Typed pipeline error surfaced with node context.
public enum NodeExecutionError: Error, LocalizedError, Sendable {
    case missingInput(String)
    case invalidParameter(String)
    case scriptTimedOut(seconds: Double)
    case scriptFailed(String)
    case authorizationDenied(String)
    case userCancelled
    case memoryPressureAbort
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let msg): return msg
        case .invalidParameter(let msg): return msg
        case .scriptTimedOut(let sec): return "Script exceeded \(sec)s watchdog timeout."
        case .scriptFailed(let msg): return "Script error: \(msg)"
        case .authorizationDenied(let msg): return msg
        case .userCancelled: return "Cancelled by user."
        case .memoryPressureAbort: return "Export aborted due to critical system memory pressure."
        case .encodingFailed(let msg): return "Encoding error: \(msg)"
        }
    }
}

/// Routed output from a node, specifying which output port (`0` default, `1` unmatched on `Rules`) receives the asset.
public struct RoutedAsset: Sendable {
    public let portIndex: Int
    public let asset: PipelineAsset

    public init(portIndex: Int = 0, asset: PipelineAsset) {
        self.portIndex = portIndex
        self.asset = asset
    }
}

/// Shared execution context passed into every node executor.
public struct NodeExecutionContext: @unchecked Sendable {
    public let isPreview: Bool
    public let previewContext: CIContext
    public let exportContext: CIContext
    public let rawScaleFactor: Float
    public let subsampleFactor: Int
    public let promptService: any UserPromptService
    public let jsWorkerURL: URL?
    public let pasteboardName: NSPasteboard.Name?
    public let photosAuthorizationOverride: PHAuthorizationStatus?
    public let logHandler: @Sendable (UUID?, String, ConsoleLogEntry.Level, String) -> Void

    public var activeCIContext: CIContext {
        isPreview ? previewContext : exportContext
    }

    public init(
        isPreview: Bool,
        previewContext: CIContext,
        exportContext: CIContext,
        rawScaleFactor: Float = 1.0,
        subsampleFactor: Int = 1,
        promptService: any UserPromptService = NoopPromptService(),
        jsWorkerURL: URL? = nil,
        pasteboardName: NSPasteboard.Name? = nil,
        photosAuthorizationOverride: PHAuthorizationStatus? = nil,
        logHandler: @escaping @Sendable (UUID?, String, ConsoleLogEntry.Level, String) -> Void = { _, _, _, _ in }
    ) {
        self.isPreview = isPreview
        self.previewContext = previewContext
        self.exportContext = exportContext
        self.rawScaleFactor = rawScaleFactor
        self.subsampleFactor = subsampleFactor
        self.promptService = promptService
        self.jsWorkerURL = jsWorkerURL
        self.pasteboardName = pasteboardName
        self.photosAuthorizationOverride = photosAuthorizationOverride
        self.logHandler = logHandler
    }

    public func log(_ node: WorkflowNode, level: ConsoleLogEntry.Level, _ message: String) {
        logHandler(node.id, node.title, level, message)
    }
}

/// Shared layout helpers reused by Watermark and Transform executors.
public enum AnchorLayout {
    public static func origin(
        anchor: String,
        canvasSize: CGSize,
        overlaySize: CGSize,
        marginX: CGFloat,
        marginY: CGFloat
    ) -> CGPoint {
        let x: CGFloat
        if anchor.lowercased().contains("left") {
            x = marginX
        } else if anchor.lowercased().contains("right") {
            x = canvasSize.width - overlaySize.width - marginX
        } else {
            x = (canvasSize.width - overlaySize.width) * 0.5
        }

        // Core Image Y=0 is at the bottom
        let y: CGFloat
        if anchor.lowercased().contains("top") {
            y = canvasSize.height - overlaySize.height - marginY
        } else if anchor.lowercased().contains("bottom") {
            y = marginY
        } else {
            y = (canvasSize.height - overlaySize.height) * 0.5
        }
        return CGPoint(x: x, y: y)
    }

    /// Maps human-readable blend mode names to Core Image compositor filter names.
    public static func blendFilterName(for mode: String) -> String {
        switch mode {
        case "Multiply": return "CIMultiplyBlendMode"
        case "Screen": return "CIScreenBlendMode"
        case "Overlay": return "CIOverlayBlendMode"
        case "Darken": return "CIDarkenBlendMode"
        case "Lighten": return "CILightenBlendMode"
        case "Color Dodge": return "CIColorDodgeBlendMode"
        case "Color Burn": return "CIColorBurnBlendMode"
        case "Soft Light": return "CISoftLightBlendMode"
        case "Hard Light": return "CIHardLightBlendMode"
        case "Difference": return "CIDifferenceBlendMode"
        case "Exclusion": return "CIExclusionBlendMode"
        case "Hue": return "CIHueBlendMode"
        case "Saturation": return "CISaturationBlendMode"
        case "Color": return "CIColorBlendMode"
        case "Luminosity": return "CILuminosityBlendMode"
        case "Plus Darker": return "CIDarkenBlendMode"
        case "Plus Lighter": return "CIAdditionCompositing"
        case "Pin Light": return "CIPinLightBlendMode"
        case "Divide": return "CIDivideBlendMode"
        default: return "CISourceOverCompositing"
        }
    }

    public static func composite(overlay: CIImage, over background: CIImage, blendMode: String) -> CIImage {
        let filterName = blendFilterName(for: blendMode)
        if let filter = CIFilter(name: filterName) {
            filter.setValue(overlay, forKey: kCIInputImageKey)
            filter.setValue(background, forKey: kCIInputBackgroundImageKey)
            if let out = filter.outputImage {
                return out.cropped(to: background.extent)
            }
        }
        return overlay.composited(over: background).cropped(to: background.extent)
    }
}
