import CoreGraphics
import CoreImage
import CZlib
import Foundation

/// Options controlling clean-room indexed PNG quantization and chunk compression.
public struct IndexedPNGOptions: Sendable {
    public var maxColors: Int
    public var speed: Int
    public var dither: Bool
    public var removeAlphaIfOpaque: Bool
    public var removeColorProfile: Bool
    public var crush: Bool
    public var bruteForceCrush: Bool

    public init(
        maxColors: Int = 256,
        speed: Int = 1,
        dither: Bool = false,
        removeAlphaIfOpaque: Bool = true,
        removeColorProfile: Bool = false,
        crush: Bool = false,
        bruteForceCrush: Bool = false
    ) {
        self.maxColors = max(2, min(256, maxColors))
        self.speed = max(1, min(10, speed))
        self.dither = dither
        self.removeAlphaIfOpaque = removeAlphaIfOpaque
        self.removeColorProfile = removeColorProfile
        self.crush = crush
        self.bruteForceCrush = bruteForceCrush
    }
}

public enum IndexedPNGError: Error, LocalizedError {
    case invalidExtent
    case renderFailed
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidExtent: return "Cannot encode image with zero or infinite extent."
        case .renderFailed: return "Failed to rasterize image into RGBA8 sRGB buffer."
        case .compressionFailed: return "Failed to deflate PNG scanline buffer with zlib."
        }
    }
}

/// Clean-room Median-Cut color quantizer, Floyd-Steinberg ditherer, and manual PNG chunk writer
/// (IHDR -> optional sRGB -> PLTE -> optional tRNS -> IDAT -> IEND) backed by `CZlib` (`-lz`).
public enum IndexedPNGQuantizer {
    private struct RGBAPixel: Hashable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
    }

    /// Encodes a `CIImage` to valid 1/2/4/8-bit indexed PNG `Data` (Color Type 3).
    public static func encode(
        image: CIImage,
        context: CIContext,
        options: IndexedPNGOptions = IndexedPNGOptions()
    ) throws -> Data {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0, !extent.isInfinite else {
            throw IndexedPNGError.invalidExtent
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rowBytes = width * 4
        var rgba = [UInt8](repeating: 0, count: rowBytes * height)
        rgba.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: rowBytes,
                bounds: extent,
                format: .RGBA8,
                colorSpace: srgb
            )
        }

        return try encodeRGBA8Buffer(rgba, width: width, height: height, options: options)
    }

    /// Directly quantizes and encodes a top-down `RGBA8` byte buffer (`width * height * 4`).
    public static func encodeRGBA8Buffer(
        _ rgbaInput: [UInt8],
        width: Int,
        height: Int,
        options: IndexedPNGOptions = IndexedPNGOptions()
    ) throws -> Data {
        guard width > 0, height > 0, rgbaInput.count >= width * height * 4 else {
            throw IndexedPNGError.renderFailed
        }

        let pixelCount = width * height
        var hasTransparency = false
        var pixels = [RGBAPixel](repeating: RGBAPixel(r: 0, g: 0, b: 0, a: 255), count: pixelCount)

        for i in 0..<pixelCount {
            let offset = i * 4
            var r = rgbaInput[offset]
            var g = rgbaInput[offset + 1]
            var b = rgbaInput[offset + 2]
            let a = rgbaInput[offset + 3]

            // Unpremultiply RGB when partially transparent so PLTE colors stay accurate
            if a > 0 && a < 255 {
                let af = Int(a)
                r = UInt8(min(255, (Int(r) * 255 + af / 2) / af))
                g = UInt8(min(255, (Int(g) * 255 + af / 2) / af))
                b = UInt8(min(255, (Int(b) * 255 + af / 2) / af))
                hasTransparency = true
            } else if a == 0 {
                r = 0; g = 0; b = 0
                hasTransparency = true
            }
            pixels[i] = RGBAPixel(r: r, g: g, b: b, a: a)
        }

        if options.removeAlphaIfOpaque && !hasTransparency {
            // Confirm opaque alpha stays stripped from palette & tRNS
            hasTransparency = false
        }

        // Build representative sample set capped cleanly so large images quantize in milliseconds
        let targetSampleCap = max(4_096, 48_000 / options.speed)
        let stride = max(1, max(options.speed == 1 ? 1 : options.speed * 2, pixelCount / targetSampleCap))
        var samples: [RGBAPixel] = []
        samples.reserveCapacity(min(pixelCount, targetSampleCap))
        var idx = 0
        while idx < pixelCount {
            samples.append(pixels[idx])
            idx += stride
        }
        if samples.isEmpty {
            samples.append(pixels[0])
        }

        var palette = medianCutPalette(samples: samples, maxColors: options.maxColors, includeAlpha: hasTransparency)

        // Sort transparent/translucent entries first so tRNS chunk can terminate cleanly
        palette.sort { lhs, rhs in
            if lhs.a != rhs.a { return lhs.a < rhs.a }
            if lhs.r != rhs.r { return lhs.r < rhs.r }
            if lhs.g != rhs.g { return lhs.g < rhs.g }
            return lhs.b < rhs.b
        }
        if palette.isEmpty {
            palette = [RGBAPixel(r: 0, g: 0, b: 0, a: 255)]
        }

        // Map pixels to palette indices (with optional Floyd-Steinberg dithering)
        let indices = mapPixels(pixels, width: width, height: height, palette: palette, dither: options.dither, includeAlpha: hasTransparency)

        // Choose minimal PNG bit depth for Color Type 3 (1, 2, 4, or 8 bits per pixel)
        let bitDepth: Int
        if palette.count <= 2 {
            bitDepth = 1
        } else if palette.count <= 4 {
            bitDepth = 2
        } else if palette.count <= 16 {
            bitDepth = 4
        } else {
            bitDepth = 8
        }

        let packedRows = packIndexedScanlines(indices: indices, width: width, height: height, bitDepth: bitDepth)
        let compressedIDAT = try compressScanlines(packedRows: packedRows, width: width, height: height, bitDepth: bitDepth, options: options)

        return assemblePNG(
            width: width,
            height: height,
            bitDepth: bitDepth,
            palette: palette,
            hasTransparency: hasTransparency,
            removeColorProfile: options.removeColorProfile,
            idatPayload: compressedIDAT
        )
    }

    // MARK: - Median-Cut Color Quantization

    private struct ColorBox {
        var slice: ArraySlice<RGBAPixel>

        func channelRanges() -> (r: Int, g: Int, b: Int, a: Int) {
            var minR: UInt8 = 255, maxR: UInt8 = 0
            var minG: UInt8 = 255, maxG: UInt8 = 0
            var minB: UInt8 = 255, maxB: UInt8 = 0
            var minA: UInt8 = 255, maxA: UInt8 = 0
            for p in slice {
                if p.r < minR { minR = p.r }; if p.r > maxR { maxR = p.r }
                if p.g < minG { minG = p.g }; if p.g > maxG { maxG = p.g }
                if p.b < minB { minB = p.b }; if p.b > maxB { maxB = p.b }
                if p.a < minA { minA = p.a }; if p.a > maxA { maxA = p.a }
            }
            return (Int(maxR) - Int(minR), Int(maxG) - Int(minG), Int(maxB) - Int(minB), Int(maxA) - Int(minA))
        }

        func maxRange(includeAlpha: Bool) -> Int {
            let r = channelRanges()
            return includeAlpha ? max(r.r, r.g, r.b, r.a) : max(r.r, r.g, r.b)
        }

        func averageColor(includeAlpha: Bool) -> RGBAPixel {
            guard !slice.isEmpty else { return RGBAPixel(r: 0, g: 0, b: 0, a: 255) }
            var sr = 0, sg = 0, sb = 0, sa = 0
            for p in slice {
                sr += Int(p.r); sg += Int(p.g); sb += Int(p.b); sa += Int(p.a)
            }
            let c = slice.count
            return RGBAPixel(
                r: UInt8(sr / c),
                g: UInt8(sg / c),
                b: UInt8(sb / c),
                a: includeAlpha ? UInt8(sa / c) : 255
            )
        }
    }

    private static func medianCutPalette(samples: [RGBAPixel], maxColors: Int, includeAlpha: Bool) -> [RGBAPixel] {
        var uniqueCheck = Set<RGBAPixel>()
        for s in samples {
            uniqueCheck.insert(includeAlpha ? s : RGBAPixel(r: s.r, g: s.g, b: s.b, a: 255))
            if uniqueCheck.count > maxColors { break }
        }
        if uniqueCheck.count <= maxColors {
            return Array(uniqueCheck)
        }

        let working = samples
        var boxes: [ColorBox] = [ColorBox(slice: working[...])]

        while boxes.count < maxColors {
            // Find splittable box with largest color spread
            var bestIdx: Int?
            var bestRange = 0
            for (i, box) in boxes.enumerated() where box.slice.count > 1 {
                let range = box.maxRange(includeAlpha: includeAlpha)
                if range > bestRange {
                    bestRange = range
                    bestIdx = i
                }
            }
            guard let splitIdx = bestIdx, bestRange > 0 else { break }

            let box = boxes.remove(at: splitIdx)
            var sub = Array(box.slice)
            let ranges = box.channelRanges()
            let maxChannel = includeAlpha ? max(ranges.r, ranges.g, ranges.b, ranges.a) : max(ranges.r, ranges.g, ranges.b)

            if includeAlpha && ranges.a == maxChannel {
                sub.sort { $0.a < $1.a }
            } else if ranges.r == maxChannel {
                sub.sort { $0.r < $1.r }
            } else if ranges.g == maxChannel {
                sub.sort { $0.g < $1.g }
            } else {
                sub.sort { $0.b < $1.b }
            }

            let mid = sub.count / 2
            boxes.append(ColorBox(slice: sub[..<mid]))
            boxes.append(ColorBox(slice: sub[mid...]))
        }

        // Deduplicate centroids while keeping order
        var seen = Set<RGBAPixel>()
        var palette: [RGBAPixel] = []
        for box in boxes {
            let avg = box.averageColor(includeAlpha: includeAlpha)
            if seen.insert(avg).inserted {
                palette.append(avg)
            }
        }
        return palette
    }

    // MARK: - Pixel Mapping & Floyd-Steinberg Dithering

    private struct SortedPaletteEntry {
        let origIndex: UInt8
        let r: Int
        let g: Int
        let b: Int
        let a: Int
        let luma: Int
    }

    private static func buildSortedPalette(_ palette: [RGBAPixel]) -> [SortedPaletteEntry] {
        palette.enumerated().map { idx, p in
            let luma = 299 * Int(p.r) + 587 * Int(p.g) + 114 * Int(p.b)
            return SortedPaletteEntry(
                origIndex: UInt8(idx),
                r: Int(p.r),
                g: Int(p.g),
                b: Int(p.b),
                a: Int(p.a),
                luma: luma
            )
        }.sorted { $0.luma < $1.luma }
    }

    /// Mathematically exact nearest palette entry using Cauchy-Schwarz luminance branch-and-bound pruning.
    private static func nearestIndex(
        r: Int, g: Int, b: Int, a: Int,
        sortedPalette: [SortedPaletteEntry],
        includeAlpha: Bool
    ) -> UInt8 {
        let count = sortedPalette.count
        guard count > 1 else { return sortedPalette.first?.origIndex ?? 0 }

        let targetLuma = 299 * r + 587 * g + 114 * b

        // Binary search closest luminance starting position
        var lo = 0
        var hi = count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if sortedPalette[mid].luma < targetLuma {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        var left = lo - 1
        var right = lo
        var bestIdx: UInt8 = sortedPalette[min(lo, count - 1)].origIndex
        var bestDist = Int.max

        // Since Cauchy-Schwarz applies purely to RGB distance, RGB+2*alpha^2 >= RGB distance,
        // meaning dluma^2 / 446966 <= rgbDistSq <= totalDistSq holds with alpha included too!
        let lumaScaleFactor: Int64 = 446_966

        while left >= 0 || right < count {
            if right < count {
                let e = sortedPalette[right]
                let dl = Int64(e.luma - targetLuma)
                if bestDist < Int.max && (dl * dl) > Int64(bestDist) * lumaScaleFactor {
                    right = count // Prune all remaining entries to the right
                } else {
                    let dr = r - e.r
                    let dg = g - e.g
                    let db = b - e.b
                    var d = dr * dr + dg * dg + db * db
                    if includeAlpha {
                        let da = a - e.a
                        d += da * da * 2
                    }
                    if d == 0 { return e.origIndex }
                    if d < bestDist {
                        bestDist = d
                        bestIdx = e.origIndex
                    }
                    right += 1
                }
            }

            if left >= 0 {
                let e = sortedPalette[left]
                let dl = Int64(targetLuma - e.luma)
                if bestDist < Int.max && (dl * dl) > Int64(bestDist) * lumaScaleFactor {
                    left = -1 // Prune all remaining entries to the left
                } else {
                    let dr = r - e.r
                    let dg = g - e.g
                    let db = b - e.b
                    var d = dr * dr + dg * dg + db * db
                    if includeAlpha {
                        let da = a - e.a
                        d += da * da * 2
                    }
                    if d == 0 { return e.origIndex }
                    if d < bestDist {
                        bestDist = d
                        bestIdx = e.origIndex
                    }
                    left -= 1
                }
            }
        }
        return bestIdx
    }

    private static func mapPixels(
        _ pixels: [RGBAPixel],
        width: Int,
        height: Int,
        palette: [RGBAPixel],
        dither: Bool,
        includeAlpha: Bool
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let sortedPalette = buildSortedPalette(palette)

        if !dither {
            // Fast direct-mapped open cache (16,384 slots) to skip repeated exact RGBA colors
            let cacheSize = 16_384
            let cacheMask = cacheSize - 1
            var cacheKeys = [UInt32](repeating: 0x0000_0001, count: cacheSize) // impossible sentinel since alpha/rgb XOR handles collision via valid check
            var cacheValid = [Bool](repeating: false, count: cacheSize)
            var cacheVals = [UInt8](repeating: 0, count: cacheSize)

            for i in 0..<pixels.count {
                let p = pixels[i]
                let aByte: UInt32 = includeAlpha ? UInt32(p.a) : 255
                let key = (UInt32(p.r) << 24) | (UInt32(p.g) << 16) | (UInt32(p.b) << 8) | aByte
                let slot = Int((key &* 2654435761) >> 18) & cacheMask
                if cacheValid[slot] && cacheKeys[slot] == key {
                    out[i] = cacheVals[slot]
                } else {
                    let idx = nearestIndex(
                        r: Int(p.r), g: Int(p.g), b: Int(p.b), a: Int(aByte),
                        sortedPalette: sortedPalette, includeAlpha: includeAlpha
                    )
                    cacheKeys[slot] = key
                    cacheVals[slot] = idx
                    cacheValid[slot] = true
                    out[i] = idx
                }
            }
            return out
        }

        // Floyd-Steinberg error diffusion in float accumulator buffers
        var workR = pixels.map { Double($0.r) }
        var workG = pixels.map { Double($0.g) }
        var workB = pixels.map { Double($0.b) }
        var workA = pixels.map { Double(includeAlpha ? $0.a : 255) }

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let cr = max(0, min(255, Int(workR[i].rounded())))
                let cg = max(0, min(255, Int(workG[i].rounded())))
                let cb = max(0, min(255, Int(workB[i].rounded())))
                let ca = max(0, min(255, Int(workA[i].rounded())))

                let palIdx = nearestIndex(
                    r: cr, g: cg, b: cb, a: ca,
                    sortedPalette: sortedPalette, includeAlpha: includeAlpha
                )
                out[i] = palIdx
                let chosen = palette[Int(palIdx)]

                let er = workR[i] - Double(chosen.r)
                let eg = workG[i] - Double(chosen.g)
                let eb = workB[i] - Double(chosen.b)
                let ea = includeAlpha ? (workA[i] - Double(chosen.a)) : 0

                func distribute(_ nx: Int, _ ny: Int, _ factor: Double) {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { return }
                    let ni = ny * width + nx
                    workR[ni] += er * factor
                    workG[ni] += eg * factor
                    workB[ni] += eb * factor
                    if includeAlpha { workA[ni] += ea * factor }
                }

                distribute(x + 1, y, 7.0 / 16.0)
                distribute(x - 1, y + 1, 3.0 / 16.0)
                distribute(x, y + 1, 5.0 / 16.0)
                distribute(x + 1, y + 1, 1.0 / 16.0)
            }
        }
        return out
    }

    // MARK: - Bit-Depth Packing & PNG Row Filters

    private static func packIndexedScanlines(indices: [UInt8], width: Int, height: Int, bitDepth: Int) -> [[UInt8]] {
        let rowByteCount = (width * bitDepth + 7) / 8
        var rows: [[UInt8]] = []
        rows.reserveCapacity(height)

        for y in 0..<height {
            let rowStart = y * width
            if bitDepth == 8 {
                rows.append(Array(indices[rowStart..<(rowStart + width)]))
            } else {
                var packed = [UInt8](repeating: 0, count: rowByteCount)
                let pixelsPerByte = 8 / bitDepth
                for x in 0..<width {
                    let byteIdx = x / pixelsPerByte
                    let shift = (pixelsPerByte - 1 - (x % pixelsPerByte)) * bitDepth
                    packed[byteIdx] |= (indices[rowStart + x] << shift)
                }
                rows.append(packed)
            }
        }
        return rows
    }

    private static func paethPredictor(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return UInt8(a) }
        if pb <= pc { return UInt8(b) }
        return UInt8(c)
    }

    private static func buildFilteredStream(packedRows: [[UInt8]], mode: Int) -> [UInt8] {
        guard let first = packedRows.first else { return [] }
        let rowBytes = first.count
        var stream = [UInt8]()
        stream.reserveCapacity(packedRows.count * (rowBytes + 1))

        var prevRow = [UInt8](repeating: 0, count: rowBytes)

        for row in packedRows {
            let chosenFilter: UInt8
            if mode >= 0 && mode <= 4 {
                chosenFilter = UInt8(mode)
            } else {
                // Adaptive minimum sum-of-absolute-differences heuristic
                var bestFilter: UInt8 = 0
                var bestScore = Int.max
                for f: UInt8 in 0...4 {
                    var score = 0
                    for x in 0..<rowBytes {
                        let raw = Int(row[x])
                        let a = x > 0 ? Int(row[x - 1]) : 0
                        let b = Int(prevRow[x])
                        let c = x > 0 ? Int(prevRow[x - 1]) : 0
                        let val: Int
                        switch f {
                        case 0: val = raw
                        case 1: val = (raw - a) & 0xFF
                        case 2: val = (raw - b) & 0xFF
                        case 3: val = (raw - ((a + b) >> 1)) & 0xFF
                        default: val = (raw - Int(paethPredictor(a, b, c))) & 0xFF
                        }
                        score += val < 128 ? val : 256 - val
                    }
                    if score < bestScore {
                        bestScore = score
                        bestFilter = f
                    }
                }
                chosenFilter = bestFilter
            }

            stream.append(chosenFilter)
            for x in 0..<rowBytes {
                let raw = Int(row[x])
                let a = x > 0 ? Int(row[x - 1]) : 0
                let b = Int(prevRow[x])
                let c = x > 0 ? Int(prevRow[x - 1]) : 0
                let filtered: UInt8
                switch chosenFilter {
                case 0: filtered = row[x]
                case 1: filtered = UInt8((raw - a) & 0xFF)
                case 2: filtered = UInt8((raw - b) & 0xFF)
                case 3: filtered = UInt8((raw - ((a + b) >> 1)) & 0xFF)
                default: filtered = UInt8((raw - Int(paethPredictor(a, b, c))) & 0xFF)
                }
                stream.append(filtered)
            }
            prevRow = row
        }
        return stream
    }

    private static func zlibCompress(_ raw: [UInt8], level: Int, strategy: FBZlibStrategy) -> Data? {
        let cap = fb_zlib_compress_bound(raw.count)
        var out = [UInt8](repeating: 0, count: cap)
        let written: Int64 = raw.withUnsafeBufferPointer { inPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                guard let inBase = inPtr.baseAddress, let outBase = outPtr.baseAddress else { return -1 }
                return fb_zlib_compress(inBase, raw.count, outBase, cap, Int32(level), strategy)
            }
        }
        guard written > 0 else { return nil }
        return Data(out[0..<Int(written)])
    }

    private static func compressScanlines(
        packedRows: [[UInt8]],
        width: Int,
        height: Int,
        bitDepth: Int,
        options: IndexedPNGOptions
    ) throws -> Data {
        if options.bruteForceCrush {
            let filterModes = [-1, 0, 1, 2, 3, 4]
            let strategies: [FBZlibStrategy] = [
                FBZlibStrategyDefault,
                FBZlibStrategyFiltered,
                FBZlibStrategyRLE
            ]
            var bestData: Data?
            for mode in filterModes {
                let raw = buildFilteredStream(packedRows: packedRows, mode: mode)
                for strat in strategies {
                    if let candidate = zlibCompress(raw, level: 9, strategy: strat) {
                        if bestData == nil || candidate.count < bestData!.count {
                            bestData = candidate
                        }
                    }
                }
            }
            guard let bestData else { throw IndexedPNGError.compressionFailed }
            return bestData
        } else if options.crush {
            // For indexed Color Type 3, Filter None (0) often beats spatial delta filters;
            // compare both Filter None and Adaptive SAD at zlib level 9 and keep the smallest output.
            let rawNone = buildFilteredStream(packedRows: packedRows, mode: 0)
            let rawAdaptive = buildFilteredStream(packedRows: packedRows, mode: -1)
            let candidates: [Data?] = [
                zlibCompress(rawNone, level: 9, strategy: FBZlibStrategyDefault),
                zlibCompress(rawNone, level: 9, strategy: FBZlibStrategyRLE),
                zlibCompress(rawAdaptive, level: 9, strategy: FBZlibStrategyDefault),
                zlibCompress(rawAdaptive, level: 9, strategy: FBZlibStrategyFiltered)
            ]
            let best = candidates.compactMap { $0 }.min(by: { $0.count < $1.count })
            guard let best else { throw IndexedPNGError.compressionFailed }
            return best
        } else {
            // PNG spec recommends Filter None (0) for indexed color type 3 unless Crush is requested
            let raw = buildFilteredStream(packedRows: packedRows, mode: 0)
            guard let data = zlibCompress(raw, level: 6, strategy: FBZlibStrategyDefault) else {
                throw IndexedPNGError.compressionFailed
            }
            return data
        }
    }

    // MARK: - Binary PNG Chunk Writer

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendChunk(type: String, payload: Data, to output: inout Data) {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)

        appendUInt32BE(UInt32(payload.count), to: &output)
        output.append(contentsOf: typeBytes)
        output.append(payload)

        var crc: UInt32 = typeBytes.withUnsafeBufferPointer { ptr in
            fb_crc32(0, ptr.baseAddress, ptr.count)
        }
        if !payload.isEmpty {
            crc = payload.withUnsafeBytes { rawPtr in
                fb_crc32(crc, rawPtr.bindMemory(to: UInt8.self).baseAddress, payload.count)
            }
        }
        appendUInt32BE(crc, to: &output)
    }

    private static func assemblePNG(
        width: Int,
        height: Int,
        bitDepth: Int,
        palette: [RGBAPixel],
        hasTransparency: Bool,
        removeColorProfile: Bool,
        idatPayload: Data
    ) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR
        var ihdr = Data()
        appendUInt32BE(UInt32(width), to: &ihdr)
        appendUInt32BE(UInt32(height), to: &ihdr)
        ihdr.append(UInt8(bitDepth))
        ihdr.append(3) // Color Type 3 = Indexed color
        ihdr.append(0) // Compression 0 = Deflate
        ihdr.append(0) // Filter 0
        ihdr.append(0) // Interlace 0 = None
        appendChunk(type: "IHDR", payload: ihdr, to: &png)

        // Optional sRGB chunk (unless stripped)
        if !removeColorProfile {
            appendChunk(type: "sRGB", payload: Data([0]), to: &png)
        }

        // PLTE
        var plte = Data(capacity: palette.count * 3)
        for entry in palette {
            plte.append(entry.r)
            plte.append(entry.g)
            plte.append(entry.b)
        }
        appendChunk(type: "PLTE", payload: plte, to: &png)

        // tRNS (only up to the last non-opaque entry)
        if hasTransparency, let lastNonOpaque = palette.lastIndex(where: { $0.a < 255 }) {
            var trns = Data(capacity: lastNonOpaque + 1)
            for i in 0...lastNonOpaque {
                trns.append(palette[i].a)
            }
            appendChunk(type: "tRNS", payload: trns, to: &png)
        }

        // IDAT
        appendChunk(type: "IDAT", payload: idatPayload, to: &png)

        // IEND
        appendChunk(type: "IEND", payload: Data(), to: &png)
        return png
    }
}
