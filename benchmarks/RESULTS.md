# Benchmarks

All numbers below were measured directly from release builds using [`benchmarks/run_benchmarks.sh`](run_benchmarks.sh). No third-party encoders were mocked or simulated; reproduce on your own hardware by running:

```bash
./benchmarks/run_benchmarks.sh
```

## Test Environment

| Property | Value |
|---|---|
| Machine | Apple M2, 8 GB unified memory |
| OS | macOS 27.2 |
| Swift Toolchain | Apple Swift 6.4.2 (`swift build -c release`) |
| Rust Toolchain | `rustc 1.100.0` (`cargo build --release`, `opt-level = "s"`, LTO) |
| Benchmark Inputs | Tracked repository assets (`docs/assets/hero-app.jpg` converted to RGB PNG, `windows/src-tauri/icons/icon.png`, and 30 JPEGs in `Resources/DemoAssets/`) |
| Timing Method | Median of 3 runs per single-image encoder mode; wall-clock + `/usr/bin/time -l` Peak RSS for 30-asset batch |

---

## 1. Clean-Room Indexed PNG (Color Type 3) — Single-Image Size & Speed

### Input A: Desktop UI Screenshot (`1600×969` RGB PNG)

| Engine & Mode | Size (bytes) | Size (KB) | vs. Baseline | Median Time | IHDR (`bit_depth` / `color_type`) |
|---|---:|---:|---:|---:|:---:|
| Swift / ImageIO 24-bit RGB PNG *(baseline)* | 829,699 | 810.3 KB | — | 64.5 ms | `8 / 2` (RGB) |
| Swift Indexed 256c (`speed=5`, no dither) | 245,388 | 239.6 KB | **-70.4%** | **49.0 ms** | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 326,149 | 318.5 KB | -60.7% | 228.0 ms | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=3`, dither + Crush) | 318,781 | 311.3 KB | **-61.6%** | 1,391.2 ms | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=1`, dither + Brute-Force) | 329,516 | 321.8 KB | -60.3% | 4,852.2 ms | `8 / 3` (PLTE) |
| Rust `image` 24-bit RGB PNG *(baseline)* | 881,075 | 860.4 KB | — | 24.3 ms | `8 / 2` (RGB) |
| Rust Indexed 256c (`speed=5`, no dither) | 140,672 | 137.4 KB | **-84.0%** | 261.7 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 387,766 | 378.7 KB | -56.0% | 894.9 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=3`, dither + `oxipng` Crush) | 352,008 | 343.8 KB | -60.0% | 1,353.6 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=1`, dither + `oxipng` Brute-Force) | 333,135 | 325.3 KB | -62.2% | 2,612.5 ms | `8 / 3` (PLTE) |

*Note: On Swift, `speed=1` samples every pixel rather than striding by 3, producing a slightly higher-entropy palette for Floyd-Steinberg dithering than `speed=3` — which is why `speed=3 + Crush` (311.3 KB) beat `speed=1 + Brute-Force` (321.8 KB) on this specific screenshot.*

### Input B: Transparent RGBA Icon (`512×512` 32-bit RGBA PNG, `PLTE` + `tRNS`)

| Engine & Mode | Size (bytes) | Size (KB) | vs. Baseline | Median Time | IHDR (`bit_depth` / `color_type`) |
|---|---:|---:|---:|---:|:---:|
| Swift / ImageIO 32-bit RGBA PNG *(baseline)* | 176,719 | 172.6 KB | — | 11.8 ms | `8 / 6` (RGBA) |
| Swift Indexed 256c (`speed=5`, no dither) | 23,304 | 22.8 KB | **-86.8%** | **7.3 ms** | `8 / 3` (PLTE+tRNS) |
| Swift Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 43,458 | 42.4 KB | -75.4% | 93.8 ms | `8 / 3` (PLTE+tRNS) |
| Swift Indexed 256c (`speed=3`, dither + Crush) | 42,782 | 41.8 KB | -75.8% | 268.0 ms | `8 / 3` (PLTE+tRNS) |
| Rust `image` 32-bit RGBA PNG *(baseline)* | 173,712 | 169.6 KB | — | 5.8 ms | `8 / 6` (RGBA) |
| Rust Indexed 256c (`speed=5`, no dither) | 17,473 | 17.1 KB | **-89.9%** | 44.0 ms | `8 / 3` (PLTE+tRNS) |
| Rust Indexed 256c (`speed=3`, dither + `oxipng` Crush) | 38,564 | 37.7 KB | -77.8% | 217.9 ms | `8 / 3` (PLTE+tRNS) |

---

## 2. 30-Asset End-to-End Batch Pipeline

Pipeline: `Read Folder (16)` + `Read Folder (14)` -> `Text Watermark` -> `Scale (Fixed 800px width)` -> `Write Images (PNG, Indexed 256c, speed=1)`.

| Engine | Files Written | Wall-Clock Time | Throughput | Total Output Size | Peak RSS (`/usr/bin/time -l`) |
|---|---:|---:|---:|---:|---:|
| **macOS Swift 6** (Metal Core Image, sequential streaming) | 30 | **601.8 ms** | **49.9 img/s** | 948.0 KB | **46.9 MB** |
| **Rust backend (`windows/src-tauri`)** (Rayon parallel, run on same M2 macOS arm64) | 30 | 2,080.1 ms | 14.4 img/s | 712.3 KB | 621.5 MB |

### Key Takeaways From These Numbers

1. **Swift's sequential streaming architecture keeps memory flat:** Processing 30 watermarked + scaled + indexed PNG exports peaked at **46.9 MB RSS** (`< 10%` of the 512 MB `CIContext` budget) and finished in **0.60 s** thanks to Metal Core Image + Cauchy-Schwarz luminance pruning inside `IndexedPNGQuantizer.swift`.
2. **Rust's current experimental backend trades RAM for simplicity:** Because `windows/src-tauri/src/pipeline.rs` currently decodes all input images into memory per stage (`HashMap<(String, usize), Vec<PipelineAsset>>`) rather than streaming per-asset, Peak RSS reached **621.5 MB** on the same 30 assets. Replacing stage buffering with per-asset streaming is the top open engineering improvement for the Windows port (see [`CONTRIBUTING.md`](../CONTRIBUTING.md)).
