import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Exported uniform type identifiers used for workflow documents and drag-and-drop node templates.
public extension UTType {
    static let flowbatchWorkflow = UTType(exportedAs: "com.local.flowbatch.workflow", conformingTo: .json)
    static let flowbatchNodeTemplate = UTType(exportedAs: "com.local.flowbatch.node-template", conformingTo: .data)
}

/// All 15 functional node categories displayed in the left sidebar.
public enum NodeCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case readImages = "Read Images"
    case writeImages = "Write Images"
    case blur = "Blur"
    case colorAdjustment = "Color Adjustment"
    case colorEffect = "Color Effect"
    case generator = "Generator"
    case metadata = "Metadata"
    case misc = "Misc"
    case pdf = "PDF"
    case photosLibrary = "Photos Library"
    case script = "Script"
    case sharpen = "Sharpen"
    case sort = "Sort"
    case transform = "Transform"
    case watermark = "Watermark"

    public var id: String { rawValue }

    public var localizedName: String {
        String(localized: String.LocalizationValue(rawValue))
    }

    public var symbolName: String {
        switch self {
        case .readImages: return "folder.badge.plus"
        case .writeImages: return "square.and.arrow.down"
        case .blur: return "drop"
        case .colorAdjustment: return "slider.horizontal.3"
        case .colorEffect: return "camera.filters"
        case .generator: return "sparkles.rectangle.stack"
        case .metadata: return "tag"
        case .misc: return "wrench.and.screwdriver"
        case .pdf: return "doc.richtext"
        case .photosLibrary: return "photo.on.rectangle.angled"
        case .script: return "applescript"
        case .sharpen: return "triangle"
        case .sort: return "line.3.horizontal.decrease.circle"
        case .transform: return "crop.rotate"
        case .watermark: return "textformat.abc"
        }
    }
}

/// Failure handling strategy when an individual node fails on an asset.
public enum NodeErrorPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case skipAsset = "Skip Asset"
    case haltWorkflow = "Halt Workflow"
    case passThroughOnFailure = "Pass Input Through"

    public var id: String { rawValue }
}

/// Codable RGBA color value used in node parameters.
public struct CodableColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = CodableColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let black = CodableColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let clear = CodableColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        )!
    }
}

/// Predicate operator for the Rules sort node.
public enum RuleField: String, CaseIterable, Codable, Hashable, Sendable {
    case fileName = "File Name"
    case fileExtension = "File Extension"
    case width = "Width"
    case height = "Height"
    case megapixels = "Megapixels"
    case dpi = "DPI"
    case hasAlpha = "Has Alpha"
    case colorSpace = "Color Space"
    case classification = "Classification"
}

public enum RuleOperator: String, CaseIterable, Codable, Hashable, Sendable {
    case contains = "Contains"
    case matchesRegex = "Matches"
    case equals = "Equals"
    case greaterThan = "Greater Than"
    case lessThan = "Less Than"
    case isTrue = "Is True"
    case isFalse = "Is False"
}

public struct FilterRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(id: UUID = UUID(), field: RuleField = .width, op: RuleOperator = .greaterThan, value: String = "1000") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

/// Output scale branch configuration for Multi Scale node.
public struct ScaleBranchSpec: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var scaleFactor: Double
    public var suffix: String

    public init(id: UUID = UUID(), label: String = "2x", scaleFactor: Double = 2.0, suffix: String = "@2x") {
        self.id = id
        self.label = label
        self.scaleFactor = scaleFactor
        self.suffix = suffix
    }
}

/// Strongly typed parameter value stored in workflow nodes.
public enum NodeParamValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case color(CodableColor)
    case rules([FilterRule])
    case scales([ScaleBranchSpec])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var colorValue: CodableColor? {
        if case .color(let c) = self { return c }
        return nil
    }

    public var rulesValue: [FilterRule]? {
        if case .rules(let r) = self { return r }
        return nil
    }

    public var scalesValue: [ScaleBranchSpec]? {
        if case .scales(let s) = self { return s }
        return nil
    }
}

/// Parameter descriptor used to drive schema-based inspectors cleanly.
public enum ParameterControlKind: Sendable {
    case text(placeholder: String = "")
    case multilineCode(language: String)
    case folderPath
    case filePath(allowedExtensions: [String])
    case toggle
    case slider(min: Double, max: Double, step: Double = 0.01, unit: String = "")
    case intSlider(min: Int, max: Int, unit: String = "")
    case picker(options: [String])
    case color
    case anchorGrid
    case tokenField
}

public struct ParameterDescriptor: Identifiable, Sendable {
    public let key: String
    public let label: String
    public let kind: ParameterControlKind
    public let defaultValue: NodeParamValue

    public var id: String { key }

    public init(key: String, label: String, kind: ParameterControlKind, defaultValue: NodeParamValue) {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// Static template metadata describing a node type available in the library.
public struct NodeDefinition: Identifiable, Sendable {
    public let typeID: String
    public let title: String
    public let category: NodeCategory
    public let summary: String
    public let inputPortCount: Int
    public let outputPortCount: Int
    public let outputPortLabels: [String]
    public let isSink: Bool
    public let isSource: Bool
    public let isBatchCollector: Bool
    public let parameters: [ParameterDescriptor]

    public var id: String { typeID }

    public var defaultParameters: [String: NodeParamValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.defaultValue) })
    }

    public init(
        typeID: String,
        title: String,
        category: NodeCategory,
        summary: String,
        inputPortCount: Int = 1,
        outputPortCount: Int = 1,
        outputPortLabels: [String] = ["Output"],
        isSink: Bool = false,
        isSource: Bool = false,
        isBatchCollector: Bool = false,
        parameters: [ParameterDescriptor] = []
    ) {
        self.typeID = typeID
        self.title = title
        self.category = category
        self.summary = summary
        self.inputPortCount = inputPortCount
        self.outputPortCount = outputPortCount
        self.outputPortLabels = outputPortLabels
        self.isSink = isSink
        self.isSource = isSource
        self.isBatchCollector = isBatchCollector
        self.parameters = parameters
    }
}
