import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Implements Metadata (`Delete Metadata`, `Remove GPS`, `Set DPI`, `Set General Metadata`, `Fix EXIF Rotation`)
/// and Sort (`Rules`, `Classify Images`, `Sort Order`) nodes.
public enum MetadataSortExecutors {
    public static func execute(
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws -> [RoutedAsset] {
        switch node.typeID {
        case NodeTypeID.deleteMetadata:
            let keepOrient = node.parameters["keepOrientation"]?.boolValue ?? true
            let savedOrient = asset.metadata[kCGImagePropertyOrientation as String]
            asset.metadata.removeAll()
            if keepOrient, let savedOrient {
                asset.metadata[kCGImagePropertyOrientation as String] = savedOrient
            }
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.removeGPS:
            asset.metadata.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.setDPI:
            let dpi = max(36, node.parameters["dpi"]?.intValue ?? 300)
            asset.dpi = dpi
            asset.metadata[kCGImagePropertyDPIWidth as String] = dpi
            asset.metadata[kCGImagePropertyDPIHeight as String] = dpi
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.setGeneralMetadata:
            var tiff = (asset.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            var iptc = (asset.metadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any]) ?? [:]

            let author = TokenExpander.expand(node.parameters["author"]?.stringValue ?? "", for: asset)
            let copyright = TokenExpander.expand(node.parameters["copyright"]?.stringValue ?? "", for: asset)
            let title = TokenExpander.expand(node.parameters["title"]?.stringValue ?? "", for: asset)
            let desc = TokenExpander.expand(node.parameters["description"]?.stringValue ?? "", for: asset)

            if !author.isEmpty {
                tiff[kCGImagePropertyTIFFArtist as String] = author
                iptc[kCGImagePropertyIPTCByline as String] = [author]
            }
            if !copyright.isEmpty {
                tiff[kCGImagePropertyTIFFCopyright as String] = copyright
                iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
            }
            if !title.isEmpty {
                iptc[kCGImagePropertyIPTCObjectName as String] = title
            }
            if !desc.isEmpty {
                tiff[kCGImagePropertyTIFFImageDescription as String] = desc
                iptc[kCGImagePropertyIPTCCaptionAbstract as String] = desc
            }

            asset.metadata[kCGImagePropertyTIFFDictionary as String] = tiff
            asset.metadata[kCGImagePropertyIPTCDictionary as String] = iptc
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.fixExifRotation:
            if let orientNum = asset.metadata[kCGImagePropertyOrientation as String] as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: orientNum.uint32Value),
               orientation != .up,
               let img = asset.ciImage {
                let oriented = img.oriented(orientation)
                asset.ciImage = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y))
            }
            asset.metadata[kCGImagePropertyOrientation as String] = 1
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.classifyImages:
            try classifyImage(&asset.classificationLabels, asset: asset, node: node, context: context)
            return [RoutedAsset(asset: asset)]

        case NodeTypeID.rules:
            let matchAll = node.parameters["matchAll"]?.boolValue ?? true
            let rules = node.parameters["rules"]?.rulesValue ?? []
            let matched = evaluateRules(rules, matchAll: matchAll, for: asset)
            // Port 0 = Matched, Port 1 = Unmatched
            return [RoutedAsset(portIndex: matched ? 0 : 1, asset: asset)]

        default:
            return [RoutedAsset(asset: asset)]
        }
    }

    public static func sortBatch(_ assets: [PipelineAsset], node: WorkflowNode) -> [PipelineAsset] {
        let sortBy = node.parameters["sortBy"]?.stringValue ?? "File Name"
        let ascending = node.parameters["ascending"]?.boolValue ?? true

        if sortBy == "Reverse" {
            return assets.reversed()
        }

        let sorted = assets.sorted { a, b in
            let cmp: Bool
            switch sortBy {
            case "Width":
                cmp = a.pixelSize.width < b.pixelSize.width
            case "Height":
                cmp = a.pixelSize.height < b.pixelSize.height
            case "File Size":
                cmp = a.originalByteCount < b.originalByteCount
            default:
                cmp = a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
            return ascending ? cmp : !cmp
        }
        return sorted
    }

    // MARK: - Vision Classification

    private static func classifyImage(
        _ tags: inout [ClassificationTag],
        asset: PipelineAsset,
        node: WorkflowNode,
        context: NodeExecutionContext
    ) throws {
        guard let img = asset.ciImage else { return }
        let minConf = Float(node.parameters["minConfidence"]?.doubleValue ?? 0.35)
        let maxLabels = max(1, node.parameters["maxLabels"]?.intValue ?? 5)

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: img, options: [.ciContext: context.activeCIContext])
        try handler.perform([request])

        let observations = request.results ?? []
        tags = observations
            .filter { $0.confidence >= minConf }
            .prefix(maxLabels)
            .map { ClassificationTag(identifier: $0.identifier, confidence: $0.confidence) }
    }

    // MARK: - Rule Evaluation

    public static func evaluateRules(_ rules: [FilterRule], matchAll: Bool, for asset: PipelineAsset) -> Bool {
        guard !rules.isEmpty else { return true }
        if matchAll {
            return rules.allSatisfy { evaluateRule($0, for: asset) }
        } else {
            return rules.contains { evaluateRule($0, for: asset) }
        }
    }

    private static func evaluateRule(_ rule: FilterRule, for asset: PipelineAsset) -> Bool {
        let size = asset.pixelSize
        switch rule.field {
        case .hasAlpha:
            return rule.op == .isFalse ? !asset.hasAlpha : asset.hasAlpha

        case .width:
            return compareNumeric(Double(size.width), op: rule.op, target: Double(rule.value) ?? 0)

        case .height:
            return compareNumeric(Double(size.height), op: rule.op, target: Double(rule.value) ?? 0)

        case .megapixels:
            let mp = (Double(size.width) * Double(size.height)) / 1_000_000.0
            return compareNumeric(mp, op: rule.op, target: Double(rule.value) ?? 0)

        case .dpi:
            return compareNumeric(Double(asset.dpi), op: rule.op, target: Double(rule.value) ?? 0)

        case .fileName:
            return compareString(asset.fileName, op: rule.op, target: rule.value)

        case .fileExtension:
            return compareString(asset.fileExtension, op: rule.op, target: rule.value)

        case .colorSpace:
            return compareString(asset.colorSpaceName, op: rule.op, target: rule.value)

        case .classification:
            let joined = asset.classificationLabels.map(\.identifier).joined(separator: ",")
            return compareString(joined, op: rule.op, target: rule.value)
        }
    }

    private static func compareNumeric(_ lhs: Double, op: RuleOperator, target: Double) -> Bool {
        switch op {
        case .greaterThan: return lhs > target
        case .lessThan: return lhs < target
        case .equals: return abs(lhs - target) < 0.0001
        default: return lhs >= target
        }
    }

    private static func compareString(_ lhs: String, op: RuleOperator, target: String) -> Bool {
        switch op {
        case .equals:
            return lhs.caseInsensitiveCompare(target) == .orderedSame
        case .contains:
            return lhs.localizedCaseInsensitiveContains(target)
        case .matchesRegex:
            return lhs.range(of: target, options: .regularExpression) != nil
        default:
            return lhs.localizedCaseInsensitiveContains(target)
        }
    }
}
