#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let demoRoot = root.appendingPathComponent("Resources/DemoAssets", isDirectory: true)
let aug9Dir = demoRoot.appendingPathComponent("Aug 9 Shots", isDirectory: true)
let aug11Dir = demoRoot.appendingPathComponent("Aug 11 Shots", isDirectory: true)

try FileManager.default.createDirectory(at: aug9Dir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: aug11Dir, withIntermediateDirectories: true)

struct ScenePalette {
    let skyTop: NSColor
    let skyHorizon: NSColor
    let sun: NSColor
    let foreground: NSColor
    let accent: NSColor
}

let palettes: [ScenePalette] = [
    // Golden sunset ocean (first hero image)
    ScenePalette(
        skyTop: NSColor(calibratedRed: 0.11, green: 0.27, blue: 0.49, alpha: 1),
        skyHorizon: NSColor(calibratedRed: 0.96, green: 0.67, blue: 0.30, alpha: 1),
        sun: NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.80, alpha: 1),
        foreground: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 1),
        accent: NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.35, alpha: 1)
    ),
    // Alpine dusk
    ScenePalette(
        skyTop: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.36, alpha: 1),
        skyHorizon: NSColor(calibratedRed: 0.85, green: 0.44, blue: 0.56, alpha: 1),
        sun: NSColor(calibratedRed: 0.99, green: 0.86, blue: 0.72, alpha: 1),
        foreground: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.22, alpha: 1),
        accent: NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.52, alpha: 1)
    ),
    // Coastal midday
    ScenePalette(
        skyTop: NSColor(calibratedRed: 0.16, green: 0.53, blue: 0.85, alpha: 1),
        skyHorizon: NSColor(calibratedRed: 0.67, green: 0.88, blue: 0.97, alpha: 1),
        sun: NSColor(calibratedRed: 1.0, green: 0.99, blue: 0.90, alpha: 1),
        foreground: NSColor(calibratedRed: 0.07, green: 0.34, blue: 0.48, alpha: 1),
        accent: NSColor(calibratedRed: 0.34, green: 0.76, blue: 0.85, alpha: 1)
    ),
    // Emerald forest mist
    ScenePalette(
        skyTop: NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.35, alpha: 1),
        skyHorizon: NSColor(calibratedRed: 0.72, green: 0.84, blue: 0.77, alpha: 1),
        sun: NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.84, alpha: 1),
        foreground: NSColor(calibratedRed: 0.09, green: 0.20, blue: 0.15, alpha: 1),
        accent: NSColor(calibratedRed: 0.48, green: 0.69, blue: 0.52, alpha: 1)
    ),
    // Desert twilight
    ScenePalette(
        skyTop: NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.38, alpha: 1),
        skyHorizon: NSColor(calibratedRed: 0.95, green: 0.52, blue: 0.26, alpha: 1),
        sun: NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.65, alpha: 1),
        foreground: NSColor(calibratedRed: 0.25, green: 0.13, blue: 0.10, alpha: 1),
        accent: NSColor(calibratedRed: 0.88, green: 0.45, blue: 0.25, alpha: 1)
    )
]

func renderScene(to url: URL, index: Int, width: Int, height: Int, variant: Int) throws {
    let palette = palettes[(index + variant) % palettes.count]
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fatalError("Failed to create CGContext")
    }

    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    let horizonY = CGFloat(height) * (0.42 + CGFloat((index % 3)) * 0.05)

    // Sky gradient
    if let skyGrad = CGGradient(
        colorsSpace: cs,
        colors: [palette.skyHorizon.cgColor, palette.skyTop.cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizonY, width: CGFloat(width), height: CGFloat(height) - horizonY))
        ctx.drawLinearGradient(
            skyGrad,
            start: CGPoint(x: 0, y: horizonY),
            end: CGPoint(x: 0, y: CGFloat(height)),
            options: []
        )
        ctx.restoreGState()
    }

    // Sun glow + disc
    let sunX = CGFloat(width) * (0.32 + CGFloat((index * 17) % 38) / 100.0)
    let sunY = horizonY + CGFloat(height) * 0.09
    if let glow = CGGradient(
        colorsSpace: cs,
        colors: [
            palette.sun.cgColor,
            palette.accent.withAlphaComponent(0.45).cgColor,
            palette.skyHorizon.withAlphaComponent(0.0).cgColor
        ] as CFArray,
        locations: [0.0, 0.35, 1.0]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: sunX, y: sunY),
            startRadius: 4,
            endCenter: CGPoint(x: sunX, y: sunY),
            endRadius: CGFloat(width) * 0.36,
            options: []
        )
    }

    // Water / foreground gradient
    if let fgGrad = CGGradient(
        colorsSpace: cs,
        colors: [palette.foreground.cgColor, palette.skyHorizon.withAlphaComponent(0.65).cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: horizonY))
        ctx.drawLinearGradient(
            fgGrad,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: horizonY),
            options: []
        )
        ctx.restoreGState()
    }

    // Mountain ridge or ocean shimmer depending on index parity
    if index % 2 == 0 {
        // Ocean sun reflection streaks
        ctx.setFillColor(palette.sun.withAlphaComponent(0.32).cgColor)
        for step in 0..<24 {
            let t = CGFloat(step) / 24.0
            let y = horizonY * (1.0 - t)
            let w = (18.0 + t * 180.0) * (0.7 + 0.5 * sin(CGFloat(step + index)))
            let x = sunX - w * 0.5 + sin(CGFloat(step * 3 + index)) * 18.0
            ctx.fill(CGRect(x: x, y: y, width: max(10, w), height: 3.5))
        }
    } else {
        // Layered silhouettes
        ctx.setFillColor(palette.foreground.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: horizonY))
        let peaks = 6
        for p in 0...peaks {
            let px = CGFloat(p) / CGFloat(peaks) * CGFloat(width)
            let py = horizonY + (p % 2 == 0 ? 18 : 88 + CGFloat((index * 13 + p * 7) % 55))
            ctx.addLine(to: CGPoint(x: px, y: py))
        }
        ctx.addLine(to: CGPoint(x: CGFloat(width), y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: 0))
        ctx.closePath()
        ctx.fillPath()
    }

    // Subtle soft cloud bands
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    for c in 0..<4 {
        let cy = horizonY + CGFloat(c + 1) * CGFloat(height) * 0.10
        let cw = CGFloat(width) * (0.35 + CGFloat((index + c) % 3) * 0.14)
        let cx = CGFloat((index * 83 + c * 173) % max(1, width - Int(cw)))
        ctx.fillEllipse(in: CGRect(x: cx, y: cy, width: cw, height: 26))
    }

    guard let cgImage = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
          ) else {
        fatalError("Failed to create image destination for \(url.path)")
    }

    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.88,
        kCGImagePropertyDPIWidth: 72,
        kCGImagePropertyDPIHeight: 72,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "FlowBatch Sample Asset #\(index + 1)",
            kCGImagePropertyExifDateTimeOriginal: "2026:08:\(variant == 0 ? "09" : "11") 18:\(String(format: "%02d", index)):00"
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "FlowBatch Sample",
            kCGImagePropertyTIFFModel: "FB-1"
        ]
    ]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to write \(url.path)")
    }
    _ = rect
}

for i in 0..<16 {
    let url = aug9Dir.appendingPathComponent(String(format: "Shot_0809_%02d.jpg", i + 1))
    try renderScene(to: url, index: i, width: 1200, height: 800, variant: 0)
}

for i in 0..<14 {
    let url = aug11Dir.appendingPathComponent(String(format: "Shot_0811_%02d.jpg", i + 1))
    try renderScene(to: url, index: i, width: 1200, height: 800, variant: 2)
}

print("Generated 30 demo assets (16 + 14) in \(demoRoot.path)")
