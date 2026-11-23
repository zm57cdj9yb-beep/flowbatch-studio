# FlowBatch Studio

**Native macOS node-based batch image processor built with Swift 6, AppKit, SwiftUI, Metal, and Core Image.**

> ![FlowBatch Studio Demo Placeholder](docs/demo-placeholder.png)
> *Visual workspace preview placeholder — capture a 10–15s workflow GIF/screenshot on macOS and place it at `docs/demo-placeholder.png` before publishing.*

---

## Overview

FlowBatch Studio lets you compose visual image-processing DAGs on a hardware-accelerated canvas: connect input sources, filters, transforms, watermarks, metadata tools, conditional rules, PDF builders, and format converters—with live preflight counts, non-destructive node bypass toggles, coalesced Undo/Redo, and `.flowbatch` JSON workflow persistence.

## Features

- **15 Node Categories (67 Built-In Nodes)**:
  - **Read Images**: `Read Folder`, `Read Individual Files`, `Prompt for Files`, `Clipboard`, `RAW Process` (`CIRAWFilter`)
  - **Write Images**: `Write Images` (PNG, JPEG, HEIC, AVIF, TIFF, GIF, JPEG 2000, BMP, PDF, PSD), `Write to Clipboard`, `Open in Another App`, `Multi Scale` (`@1x`/`@2x`/`@3x`)
  - **Blur & Sharpen**: `Gaussian Blur`, `Box Blur`, `Motion Blur`, `Noise Reduction`, `Pixelate`, `Sharpen Luminance`, `Unsharp Mask`
  - **Color Adjustment & Effects**: `Exposure`, `Brightness & Contrast`, `Vibrance`, `Gamma`, `Temperature & Tint`, `Shadows & Highlights`, `Color Profile` (sRGB, Display P3, Adobe RGB, Grayscale, CMYK), `Photo Effect`, `Sepia`, `Color Invert`, `Color Posterize`, `1-Bit` (Floyd-Steinberg), `Dither`, `Matte`, `Add Border`, `Drop Shadow`, `Document Enhancer`
  - **Transform & Watermark**: `Scale`, `Crop`, `Rotate`, `Flip`, `Trim to Edges`, `ML Super Resolution`, `Text Watermark` (tokenized), `Image Watermark` (20 blend modes + tiling)
  - **Metadata & Sort**: `Delete Metadata`, `Remove GPS`, `Set DPI`, `Set General Metadata`, `Fix EXIF Rotation`, `Rules` (2-port Matched/Unmatched branching), `Classify Images` (`Vision`), `Sort Order`
  - **PDF, Generator, Misc, Photos & Script**: `PDF Maker`, `PDF Image Extractor`, `Layer & Page Splitter`, `Blank Image`, `Screenshot` (`ScreenCaptureKit`), `Image Grid`, `Animated Image` (GIF), `Change Bits Per Channel`, `Duplicate`, `Delay`, `Extract Portrait Matte`, `Contrast Stretch`, `Custom Convolution`, `Read Photos Library`, `Import to Photos`, `JavaScript`, `Shell Script`, `AppleScript`
- **Live Preflight Dry-Run**: Real-time asset counts per node (`16 Files`, `14 Files`, `30 Files`) and toolbar status summary (`30 assets ready to read, 30 to write.`).
- **Dynamic Token Naming**: Expand `[File Name]`, `[Width]`, `[Height]`, `[DPI]`, `[Counter]`, `[Date]`, `[Author]`, `[Copyright]`, and `[Classification]` inside file names, watermarks, and metadata tags.
- **Starter Workspace Included**: Launches with a 5-node sample workflow (`Watermark Images.flowbatch`) and 30 locally generated sample JPEG scenes (`16 + 14`).

---

## Technical Highlights

- **Zero Electron / Pure Native Swift 6**: AppKit manages the unified `NSWindow`, `NSSplitViewController`, custom `NodeGraphCanvasNSView` (graph-paper grid, directional chevron Bézier wires, marquee selection, `NSPopover` anchoring, VoiceOver accessibility elements), while SwiftUI powers the node sidebar, popover inspectors, and contact sheet.
- **Dual Metal `CIContext` & Large-Image Memory Discipline**:
  - **Interactive Preview**: `previewContext` (`.cacheIntermediates: true`) renders into `MTKView` via `CIRenderDestination`, paired with `CIRAWFilter.scaleFactor` and `CIImageOption.subsampleFactor` (on macOS 27+).
  - **Batch Export**: `exportContext` (`.cacheIntermediates: false`, `.memoryTarget: 512` MB) streams outputs via `writeJPEGRepresentation` / `writeHEIFRepresentation` / `writePNGRepresentation` inside per-asset `autoreleasepool` loops with RAM-gated concurrency (`1` concurrent export for 48MP/RAW or ≤16 GB Macs) and `DispatchSource.makeMemoryPressureSource` eviction/abort.
  - **256px ImageIO Thumbnails**: Contact-sheet tiles decode via `CGImageSourceCreateThumbnailAtIndex` (`maxPixelSize: 256`) preferring embedded RAW previews before full demosaic.
- **Clean-Room Indexed PNG Quantizer (`CZlib` + Median-Cut)**:
  - Quantizes RGBA8 images to `2...256` colors with configurable `Speed` (`1...10`), optional Floyd-Steinberg dithering, adaptive `1/2/4/8`-bit packing, PNG row filters, `Crush` / `Brute force crush` multi-strategy `zlib` compression (`-lz`), and manual binary PNG chunk assembly (`IHDR`, `sRGB`, `PLTE`, `tRNS`, `IDAT`, `IEND` with CRC-32).
- **Sandboxed JavaScript Subprocess (`FlowBatchJSWorker`)**:
  - Executes user `processAsset(asset)` scripts in an isolated `JSVirtualMachine` helper process with zero Objective-C/Cocoa exports and a `2.0s` watchdog timeout.

---

## Requirements

- **macOS 14.0+** (Sonoma or newer)
- **Xcode / Swift 6 toolchain** (`swift` and `iconutil` on `PATH`)

---

## Build, Test & Run

```bash
git clone <your-repo-url> FlowBatch-Studio
cd FlowBatch-Studio

# Build all targets (including FlowBatchJSWorker) and run the automated test suite
swift build
swift test

# Build and ad-hoc sign the native macOS .app bundle
./scripts/build_app.sh release

# Verify signature and launch the app
codesign --verify --strict --verbose=2 "build/FlowBatch Studio.app"
open "build/FlowBatch Studio.app"
```

---

## Gatekeeper Notice

`./scripts/build_app.sh` signs the helper binary and `.app` bundle locally with an **ad-hoc signature** (`codesign --sign -`). Distributed `.zip`/`.dmg` archives that have not been signed with an Apple Developer ID certificate and notarized will trigger macOS Gatekeeper on other machines. Building directly from source with the commands above avoids Gatekeeper blocks.

---

## Known Limitations & Current Verification Status

- **Automated Verification (`swift test`)**: 20/20 tests in `FlowBatchCoreTests` and `NodeCoverageTests` pass covering all 67 node type IDs, indexed PNG chunk serialization, `PDF Maker`, `Scale`, `Remove GPS`, `Rules`, `FlowBatchJSWorker` isolation/timeout, thumbnail downsampling, and 30-asset batch export.
- **Manual UI & TCC Flows**: Interactive drag-and-drop gestures, live slider preview visuals, real camera RAW files (`.dng`/`.cr3`/`.arw`), Apple Photos permissions (`Read Photos Library` / `Import to Photos`), `ScreenCaptureKit` desktop capture (`Screenshot`), and `Shell Script` / `AppleScript` UI runs depend on macOS TCC permissions and should be verified interactively on your Mac.
- **Format Note**: ImageIO on macOS encodes PNG, JPEG, HEIC, AVIF, TIFF, GIF, JPEG 2000, BMP, PDF, and PSD; WebP encoding is not supported by macOS `CGImageDestination`.

---

## License

Released under the [MIT License](LICENSE).
