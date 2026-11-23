import Foundation
import ImageIO

/// Expands metadata and workflow tokens inside text watermarks, filenames, and metadata tags.
public enum TokenExpander {
    public static let availableTokens: [(token: String, label: String)] = [
        ("[File Name]", "File Name"),
        ("[File Extension]", "File Extension"),
        ("[Parent Folder]", "Parent Folder"),
        ("[Width]", "Width"),
        ("[Height]", "Height"),
        ("[DPI]", "DPI"),
        ("[Counter]", "Counter"),
        ("[Date]", "Date"),
        ("[Year]", "Year"),
        ("[Month]", "Month"),
        ("[Day]", "Day"),
        ("[Camera Make]", "Camera Make"),
        ("[Camera Model]", "Camera Model"),
        ("[Author]", "Author"),
        ("[Copyright]", "Copyright"),
        ("[Classification]", "Classification")
    ]

    public static func expand(_ pattern: String, for asset: PipelineAsset, date: Date = Date()) -> String {
        guard pattern.contains("[") else { return pattern }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: asset.creationDate ?? date)
        let year = String(format: "%04d", comps.year ?? 2026)
        let month = String(format: "%02d", comps.month ?? 1)
        let day = String(format: "%02d", comps.day ?? 1)
        let isoDate = "\(year)-\(month)-\(day)"

        let size = asset.pixelSize
        let tiff = asset.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let iptc = asset.metadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any]

        let cameraMake = (tiff?[kCGImagePropertyTIFFMake as String] as? String) ?? ""
        let cameraModel = (tiff?[kCGImagePropertyTIFFModel as String] as? String) ?? ""
        let author = (tiff?[kCGImagePropertyTIFFArtist as String] as? String)
            ?? (iptc?[kCGImagePropertyIPTCByline as String] as? [String])?.first
            ?? ""
        let copyright = (tiff?[kCGImagePropertyTIFFCopyright as String] as? String)
            ?? (iptc?[kCGImagePropertyIPTCCopyrightNotice as String] as? String)
            ?? ""
        let topClass = asset.classificationLabels.first?.identifier ?? ""

        let replacements: [(String, String)] = [
            ("[File Name]", asset.outputNameOverride ?? asset.fileName),
            ("[File Extension]", asset.fileExtension),
            ("[Parent Folder]", asset.parentFolderName),
            ("[Width]", "\(Int(size.width))"),
            ("[Height]", "\(Int(size.height))"),
            ("[DPI]", "\(asset.dpi)"),
            ("[Counter]", String(format: "%03d", asset.sequenceIndex)),
            ("[Date]", isoDate),
            ("[Year]", year),
            ("[Month]", month),
            ("[Day]", day),
            ("[Camera Make]", cameraMake),
            ("[Camera Model]", cameraModel),
            ("[Author]", author),
            ("[Copyright]", copyright),
            ("[Classification]", topClass)
        ]

        var result = pattern
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }
}
