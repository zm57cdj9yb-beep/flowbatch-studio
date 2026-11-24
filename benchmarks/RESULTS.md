# Benchmarks

All numbers below were measured directly from release builds using [`benchmarks/run_benchmarks.sh`](run_benchmarks.sh) against **native lossless PNG fixtures** (never round-tripped through lossy JPEG). Reproduce on your own hardware:

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
| Benchmark Inputs | Native lossless `1440×872` macOS capture ([`benchmarks/fixtures/ui-lossless.png`](fixtures/ui-lossless.png), `973,538` bytes / `950.7 KB` on disk), transparent `512×512` RGBA icon ([`windows/src-tauri/icons/icon.png`](../windows/src-tauri/icons/icon.png), `176,235` bytes / `172.1 KB` on disk), and 30 JPEGs in `Resources/DemoAssets/` |
| Timing Method | Median of 3 runs per single-image encoder mode; wall-clock + `/usr/bin/time -l` Peak RSS for 30-asset batch |

*All single-image percentage reductions below are measured against each fixture's **common on-disk lossless PNG baseline** (`950.7 KB` for Input A, `172.1 KB` for Input B). Baseline re-encode rows (`ImageIO` and Rust `image`) are included for reference to show default lossless 32-bit RGBA PNG encoding speed and output variance.*

---

## 1. Clean-Room Indexed PNG (Color Type 3) — Single-Image Size & Speed

### Input A: Native Lossless Desktop UI Capture (`1440×872`, `950.7 KB` on disk)

| Engine & Mode | Size (bytes) | Size (KB) | vs. On-Disk PNG | Median Time | IHDR (`bit_depth` / `color_type`) |
|---|---:|---:|---:|---:|:---:|
| *Input fixture on disk (`ui-lossless.png`)* | 973,538 | 950.7 KB | — | — | `8 / 6` (RGBA) |
| *Reference:* Swift / ImageIO 32-bit RGBA re-encode | 988,643 | 965.5 KB | +1.6% | 40.1 ms | `8 / 6` (RGBA) |
| *Reference:* Rust `image` 32-bit RGBA re-encode | 1,039,751 | 1,015.4 KB | +6.8% | 29.6 ms | `8 / 6` (RGBA) |
| Swift Indexed 256c (`speed=5`, no dither) | 153,184 | 149.6 KB | **-84.3%** | **34.0 ms** | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 265,528 | 259.3 KB | -72.7% | 202.4 ms | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=3`, dither + Crush) | 259,078 | 253.0 KB | **-73.4%** | 1,227.3 ms | `8 / 3` (PLTE) |
| Swift Indexed 256c (`speed=1`, dither + Brute-Force) | 286,421 | 279.7 KB | -70.6% | 4,713.0 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=5`, no dither) | 105,848 | 103.4 KB | **-89.1%** | **26.7 ms** | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 279,207 | 272.7 KB | -71.3% | 408.3 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=3`, dither + `oxipng` Crush) | 251,996 | 246.1 KB | -74.1% | 838.8 ms | `8 / 3` (PLTE) |
| Rust Indexed 256c (`speed=1`, dither + `oxipng` Brute-Force) | 232,692 | 227.2 KB | **-76.1%** | 1,208.9 ms | `8 / 3` (PLTE) |

*Note: On Swift, `speed=1` samples every pixel rather than striding by 3, which captures slightly more fine-grained gradient colors into the 256-entry palette and produces a higher-entropy dithered stream than `speed=3` on this specific capture.*

### Input B: Transparent RGBA Icon (`512×512`, `172.1 KB` on disk, `PLTE` + `tRNS`)

| Engine & Mode | Size (bytes) | Size (KB) | vs. On-Disk PNG | Median Time | IHDR (`bit_depth` / `color_type`) |
|---|---:|---:|---:|---:|:---:|
| *Input fixture on disk (`icon.png`)* | 176,235 | 172.1 KB | — | — | `8 / 6` (RGBA) |
| *Reference:* Swift / ImageIO 32-bit RGBA re-encode | 176,719 | 172.6 KB | +0.3% | 11.7 ms | `8 / 6` (RGBA) |
| *Reference:* Rust `image` 32-bit RGBA re-encode | 173,712 | 169.6 KB | -1.4% | 5.5 ms | `8 / 6` (RGBA) |
| Swift Indexed 256c (`speed=5`, no dither) | 23,304 | 22.8 KB | **-86.8%** | **7.2 ms** | `8 / 3` (PLTE+tRNS) |
| Swift Indexed 256c (`speed=3`, Floyd-Steinberg dither) | 43,458 | 42.4 KB | -75.3% | 91.8 ms | `8 / 3` (PLTE+tRNS) |
| Swift Indexed 256c (`speed=3`, dither + Crush) | 42,782 | 41.8 KB | -75.7% | 259.5 ms | `8 / 3` (PLTE+tRNS) |
| Rust Indexed 256c (`speed=5`, no dither) | 18,239 | 17.8 KB | **-89.7%** | **4.8 ms** | `8 / 3` (PLTE+tRNS) |
| Rust Indexed 256c (`speed=3`, dither + `oxipng` Crush) | 39,917 | 39.0 KB | -77.4% | 144.9 ms | `8 / 3` (PLTE+tRNS) |

---

## 2. 30-Asset End-to-End Batch Pipeline

Pipeline: `Read Folder (16)` + `Read Folder (14)` -> `Text Watermark` -> `Scale (Fixed 800px width)` -> `Write Images (PNG, Indexed 256c, speed=1)`.

| Engine | Files Written | Wall-Clock Time | Throughput | Total Output Size | Peak RSS (`/usr/bin/time -l`) |
|---|---:|---:|---:|---:|---:|
| **macOS Swift 6** (Metal Core Image, sequential streaming) | 30 | **556.8 ms** | 53.9 img/s | 948.0 KB | **46.9 MB** |
| **Rust backend (`windows/src-tauri`)** (Rayon parallel + 4-asset bounded streaming, run on same M2 macOS arm64) | 30 | **382.6 ms** | **78.4 img/s** | 713.9 KB | **109.6 MB** |

### Key Takeaways From These Numbers

1. **Swift's sequential streaming keeps RSS under 50 MB:** Processing 30 watermarked + scaled + indexed PNG exports peaked at **46.9 MB RSS** (`< 10%` of the 512 MB `CIContext` budget) and finished in **556.8 ms**.
2. **Rust Median-Cut + bounded chunk streaming:** Caching `ColorBox` channel bounds with `O(N)` `select_nth_unstable_by_key` (instead of rescanning boxes and full-sorting on every split) combined with 4-asset chunked DAG streaming and reference-counted bucket moves brought Rust single-image quantization down to **26.7 ms** (1440×872) / **4.8 ms** (512×512) and the 30-asset batch down from `2,080 ms` / `621.5 MB` RSS to **382.6 ms (78.4 img/s)** / **109.6 MB Peak RSS**.
