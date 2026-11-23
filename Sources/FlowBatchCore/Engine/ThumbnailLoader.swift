import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Memory-bounded thumbnail decoder backed strictly by ImageIO (`CGImageSourceCreateThumbnailAtIndex`)
/// and an LRU `NSCache` that evicts cleanly under OS memory pressure.
public final class ThumbnailLoader: @unchecked Sendable {
    public static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 400
        c.totalCostLimit = 64 * 1024 * 1024 // ~64 MB max thumbnail cache
        return c
    }()

    public init() {}

    /// Decodes a downsampled `CGImage` thumbnail (`<= maxPixelSize`, default 256px) without decoding full-res rasters.
    /// For RAW containers, tries embedded JPEG previews first via `kCGImageSourceCreateThumbnailFromImageIfAbsent`.
    public func loadThumbnail(for url: URL, maxPixelSize: CGFloat = 256) -> CGImage? {
        let key = "\(url.path)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let src = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        let isRaw = ["dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw"].contains(ext)

        var cgImage: CGImage?
        if isRaw {
            let embeddedOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, embeddedOpts as CFDictionary)
        }

        if cgImage == nil {
            let alwaysOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, alwaysOpts as CFDictionary)
        }

        if let cgImage {
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(cgImage, forKey: key, cost: cost)
        }
        return cgImage
    }

    public func evictAll() {
        cache.removeAllObjects()
    }
}
