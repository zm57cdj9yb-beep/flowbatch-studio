#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Machine & Toolchain ==="
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
RAM_GB="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
OS_VER="$(sw_vers -productVersion 2>/dev/null || uname -sr)"
SWIFT_VER="$(swift --version 2>&1 | head -n 1)"
RUST_VER="$(rustc --version 2>&1 | head -n 1)"
GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'working-tree')"

echo "CPU:   $CPU_BRAND"
echo "RAM:   ${RAM_GB} GB"
echo "OS:    macOS $OS_VER"
echo "Swift: $SWIFT_VER"
echo "Rust:  $RUST_VER"
echo "SHA:   $GIT_SHA"

echo ""
echo "=== Building Release Benchmark Binaries ==="
(cd "$ROOT_DIR" && swift build -c release --product FlowBatchBench >/dev/null)
(cd "$ROOT_DIR/windows/src-tauri" && cargo build --release --example bench_png >/dev/null)

SWIFT_BIN="$ROOT_DIR/.build/release/FlowBatchBench"
RUST_BIN="$ROOT_DIR/windows/src-tauri/target/release/examples/bench_png"

# Prepare reproducible PNG inputs from files tracked in the repository
sips -s format png "$ROOT_DIR/docs/assets/hero-app.jpg" --out "$TMP_DIR/ui-screenshot.png" >/dev/null
cp "$ROOT_DIR/windows/src-tauri/icons/icon.png" "$TMP_DIR/app-icon-alpha.png"

echo ""
echo "=== Input 1: Desktop UI Screenshot (1600x969 RGB PNG from docs/assets/hero-app.jpg) ==="
"$SWIFT_BIN" png "$TMP_DIR/ui-screenshot.png" "$TMP_DIR/ui-swift-crushed.png"
"$RUST_BIN"  png "$TMP_DIR/ui-screenshot.png" "$TMP_DIR/ui-rust-crushed.png"

echo ""
echo "=== Input 2: Transparent RGBA Icon (512x512 RGBA PNG from windows/src-tauri/icons/icon.png) ==="
"$SWIFT_BIN" png "$TMP_DIR/app-icon-alpha.png"
"$RUST_BIN"  png "$TMP_DIR/app-icon-alpha.png"

echo ""
echo "=== Input 3: 30-Asset Starter Batch Pipeline (Watermark -> Scale 800px -> Indexed PNG 256c) ==="
echo "--- Swift 6 (Sequential GPU-offloaded streaming, 512MB CIContext cap) ---"
/usr/bin/time -l "$SWIFT_BIN" batch "$ROOT_DIR/Resources/DemoAssets" "$TMP_DIR/out-swift" 2>"$TMP_DIR/time-swift.txt"
SWIFT_RSS_BYTES="$(awk '/maximum resident set size/ {print $1}' "$TMP_DIR/time-swift.txt")"
echo "swift|peak_rss_bytes|${SWIFT_RSS_BYTES}"

echo "--- Rust (Rayon parallel batch on same macOS arm64 hardware) ---"
/usr/bin/time -l "$RUST_BIN" batch "$ROOT_DIR/Resources/DemoAssets" "$TMP_DIR/out-rust" 2>"$TMP_DIR/time-rust.txt"
RUST_RSS_BYTES="$(awk '/maximum resident set size/ {print $1}' "$TMP_DIR/time-rust.txt")"
echo "rust|peak_rss_bytes|${RUST_RSS_BYTES}"

# Optional: if BENCH_EXPORT_PROOF is set, copy the crushed UI PNG for proof comparison generation
if [ -n "${BENCH_EXPORT_PROOF:-}" ]; then
  mkdir -p "$BENCH_EXPORT_PROOF"
  cp "$TMP_DIR/ui-screenshot.png" "$BENCH_EXPORT_PROOF/ui-original.png"
  cp "$TMP_DIR/ui-swift-crushed.png" "$BENCH_EXPORT_PROOF/ui-swift-crushed.png"
  cp "$TMP_DIR/ui-rust-crushed.png" "$BENCH_EXPORT_PROOF/ui-rust-crushed.png"
fi
