# Changelog

All notable changes to FlowBatch Studio are documented in this file.

## [1.0.1] - 2026-11-24

### Fixed
- **macOS Dark Mode node cards:** Switched node card title, subtitle, and file-count text in `NodeGraphCanvasNSView` to explicit dark charcoal ink so labels stay readable on white cards when macOS Dark Mode is active.
- **Indexed PNG Crush bloat:** `IndexedPNGQuantizer` Crush mode previously evaluated only adaptive per-row SAD filtering, which inflated paletted Color Type 3 PNGs by ~27% on desktop UI captures. Crush now compares Filter None (`0`) against adaptive SAD at zlib level 9 and keeps the strictly smaller payload.
- **Lossless PNG guard:** Toggling `Crush` without `Make indexed PNG` on macOS no longer silently quantizes 24/32-bit PNGs to 256 colors.
- **Writable export formats:** Removed `PSD` from macOS writable output formats (`CGImageDestination` reads PSD only).
- **Honest node naming:** Renamed `ML Super Resolution` to `Upscale & Sharpen` on both macOS and Windows catalogs to reflect its actual Lanczos + luminance sharpen pipeline (keeping `typeID` `transform.superResolution` stable for existing `.flowbatch` files).
- **Cross-platform `.flowbatch` parameter parity:** Aligned `JavaScript` (`code`/`script`), `PDF Maker` (`Int`/`Double` margin), `Crop` (`Pixels`/`Fixed Size`), `Color Profile` (`Generic Gray`/`Grayscale`), and `Scale` (`Exact Size`) handling between Swift and Rust.

### Added
- **Experimental Windows 11 port (`windows/`):** Tauri 2 + React/TypeScript UI backed by a pure-Rust 67-node engine (`image`, `rayon`, `oxipng`, `flate2`, pure-Rust multi-page PDF 1.4) sharing the `.flowbatch` JSON format.
- **5 tested workflow recipes (`examples/`):** Ready-to-open `.flowbatch` pipelines validated by both Swift and Rust test suites (`21` Swift + `8` Rust tests).
- **Reproducible benchmark suite (`benchmarks/`):** Release Swift 6 + Rust benchmarks against native lossless PNG fixtures (`benchmarks/fixtures/ui-lossless.png` and `icon.png`) plus 30-asset batch throughput and Peak RSS.
- **Community & security docs:** `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, GitHub Issue/PR templates, and `SHA256SUMS.txt` release checksums.

### Changed
- **Rust backend performance & memory (`windows/src-tauri/`):** Replaced `O(K^2 * N)` Median-Cut box rescanning with cached `ColorBox` bounds + `O(N)` `select_nth_unstable_by_key` (9.8x faster single-image quantization: `261.7 ms -> 26.7 ms` on 1440x872) and added bounded 4-asset chunk streaming + reference-counted bucket moves (30-asset batch: `2,080 ms -> 382.6 ms`, Peak RSS `621.5 MB -> 109.6 MB`).

## [1.0.0] - 2026-11-23

### Added
- Initial native macOS 14+ release built with Swift 6, AppKit, SwiftUI, Metal/Core Image, and system `zlib` (zero external SwiftPM dependencies).
- 67 built-in nodes across 15 categories, live Metal preview (`MTKView`), 256px ImageIO contact sheet, clean-room Indexed PNG encoder, `FlowBatchJSWorker` isolated subprocess with 2.0s timeout, and 20 automated XCTest cases.
