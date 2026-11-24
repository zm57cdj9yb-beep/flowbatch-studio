# Contributing to FlowBatch Studio

Contributions, bug reports, workflow recipes, and platform parity improvements are welcome.

## Repository Layout

- `Sources/FlowBatchCore/` — Shared macOS workflow model, DAG validator, Core Image/Metal executors, and clean-room Indexed PNG encoder (zero external Swift packages).
- `Sources/FlowBatchJSWorker/` — Isolated `JavaScriptCore` subprocess binary with a 2.0s watchdog timer.
- `Sources/FlowBatchStudio/` — AppKit/SwiftUI macOS desktop app.
- `Tests/FlowBatchCoreTests/` — XCTest suite for macOS.
- `windows/` — Experimental Windows 11 port (Tauri 2 + React/TypeScript frontend + Rust backend in `windows/src-tauri/`).
- `examples/` — Cross-platform `.flowbatch` workflow recipes verified by both test suites.
- `benchmarks/` — Reproducible Swift + Rust encoding and batch throughput benchmarks.

## Running Tests Locally

### macOS (Swift 6)

```bash
swift build
swift test
```

To build and verify the ad-hoc signed `.app` bundle:

```bash
./scripts/build_app.sh release
codesign --verify --strict --verbose=2 "build/FlowBatch Studio.app"
```

### Windows Port (Tauri 2 + Rust)

```bash
cd windows
npm ci
npm run build
cd src-tauri
cargo test --release
```

## Adding or Modifying a Node

To keep `.flowbatch` files portable between macOS and Windows:

1. Keep `typeID` stable across `Sources/FlowBatchCore/Models/NodeCatalog.swift` and `windows/src-tauri/src/catalog.rs`.
2. Use identical parameter keys and value types in both catalogs.
3. Implement execution in the macOS executor (`Sources/FlowBatchCore/Engine/Executors/`) and in `windows/src-tauri/src/pipeline.rs` (or explicitly note macOS-only behavior in `README.md` if OS-specific APIs are required).
4. Add unit test coverage in both `Tests/FlowBatchCoreTests/` and `windows/src-tauri/src/lib.rs`.

## High-Impact Areas Looking for Help

- **Windows parity:** Replacing the 5×7 ASCII bitmap watermark fallback with TrueType font rendering (`ab_glyph` / `fontdue`), implementing EXIF/GPS/ICC metadata writing on Windows, and streaming batch execution instead of buffering full stages in RAM.
- **macOS concurrency:** Wiring bounded `TaskGroup` concurrency to `PipelineRunner.safeExportConcurrencyLimit` while keeping peak RSS under 512 MB on 8 GB Macs.
- **Distribution:** Signed macOS notarization / Homebrew Cask and Windows Authenticode / Winget packaging.

## Pull Request Checklist

- Keep commits focused and descriptive.
- Run `swift test` (for macOS changes) and `npm run build && cargo test --release` (for `windows/` changes).
- Verify all files in `examples/*.flowbatch` still parse and dry-run cleanly.
