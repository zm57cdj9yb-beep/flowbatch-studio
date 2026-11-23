#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG_PATH="$ROOT_DIR/Resources/AppIcon.svg"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
OUT_ICNS="$ROOT_DIR/Resources/AppIcon.icns"

mkdir -p "$ROOT_DIR/build"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$SVG_PATH" "$ICONSET_DIR" <<'SWIFT'
import AppKit
import Foundation

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: svgURL) else {
    fputs("Failed to load SVG at \(svgURL.path)\n", stderr)
    exit(1)
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in specs {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(filename)\n", stderr)
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent(filename))
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Generated $OUT_ICNS"
