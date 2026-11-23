#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="FlowBatch Studio"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
HELPERS_DIR="$CONTENTS/Helpers"
RES_DIR="$CONTENTS/Resources"

cd "$ROOT_DIR"

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    "$ROOT_DIR/scripts/build_icon.sh"
fi

if [[ ! -d "$ROOT_DIR/Resources/DemoAssets/Aug 9 Shots" ]]; then
    swift "$ROOT_DIR/scripts/generate_demo_assets.swift"
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RES_DIR"

cp "$BIN_DIR/FlowBatchStudio" "$MACOS_DIR/FlowBatchStudio"
cp "$BIN_DIR/FlowBatchJSWorker" "$HELPERS_DIR/FlowBatchJSWorker"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
cp -R "$ROOT_DIR/Resources/DemoAssets" "$RES_DIR/DemoAssets"

# Copy SwiftPM resource bundle if produced
for bundle in "$BIN_DIR"/*.bundle; do
    if [[ -d "$bundle" ]]; then
        cp -R "$bundle" "$RES_DIR/"
    fi
done

# Sign individual executables first (avoid deprecated --deep)
codesign --force --sign - "$HELPERS_DIR/FlowBatchJSWorker"
codesign --force --sign - "$MACOS_DIR/FlowBatchStudio"
codesign --force --entitlements "$ROOT_DIR/Resources/FlowBatch.entitlements" --sign - "$APP_BUNDLE"

echo "Built and signed: $APP_BUNDLE"
