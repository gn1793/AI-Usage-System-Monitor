#!/usr/bin/env bash
# Build a native macOS SwiftUI menu-bar app directly from Terminal.
# Uses Apple's Swift compiler + macOS SDK; no Xcode IDE, xcodegen, or xcodebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AIUsageSystemMonitor"
mkdir -p "$ROOT/dist"
BUILD_DIR="$(mktemp -d "$ROOT/dist/.build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'ERROR: This SwiftUI app must be built on macOS.' >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo 'ERROR: Apple Command Line Tools are required: xcode-select --install' >&2
  exit 1
fi
if ! SWIFTC="$(xcrun --find swiftc 2>/dev/null)"; then
  echo 'ERROR: Swift compiler not available. Install Apple Command Line Tools.' >&2
  exit 1
fi
if ! SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"; then
  echo 'ERROR: macOS SDK not found in active developer directory.' >&2
  exit 1
fi

mkdir -p "$MACOS" "$RESOURCES"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AIUsageSystemMonitor</string>
  <key>CFBundleIdentifier</key><string>dev.local.aiusagesystemmonitor</string>
  <key>CFBundleName</key><string>AIUsageSystemMonitor</string>
  <key>CFBundleDisplayName</key><string>AI Usage &amp; System Monitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>300</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST

cp "$ROOT/collector/monitor.py" "$RESOURCES/monitor.py"
cp "$ROOT/Resources/MenuCat.png" "$RESOURCES/MenuCat.png"
cp "$ROOT/Resources/AppIcon.png" "$RESOURCES/AppIcon.png"

# Generate conventional app icon from supplied image (never redraw it).
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$RESOURCES/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$RESOURCES/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
  rm -rf "$ICONSET"
fi

mapfile_compat() { find "$ROOT/Sources" -name '*.swift' -type f -print0; }
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(mapfile_compat)
if [[ ${#SOURCES[@]} -eq 0 ]]; then echo 'ERROR: No Swift sources found' >&2; exit 1; fi

echo "Swift compiler: $SWIFTC"
echo "macOS SDK: $SDK"
echo "Compiling ${#SOURCES[@]} Swift files without xcodebuild..."
"$SWIFTC" \
  -sdk "$SDK" \
  -O \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx26.0" \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -o "$MACOS/$APP_NAME" \
  "${SOURCES[@]}"
chmod +x "$MACOS/$APP_NAME"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null
fi
FINAL_APP="$ROOT/dist/${APP_NAME}.app"
if [[ -d "$FINAL_APP" ]]; then mv "$FINAL_APP" "$BUILD_DIR/previous.app"; fi
if ! mv "$APP" "$FINAL_APP"; then
  if [[ -d "$BUILD_DIR/previous.app" ]]; then mv "$BUILD_DIR/previous.app" "$FINAL_APP"; fi
  exit 1
fi
echo "Built: $FINAL_APP"
echo "Install: $ROOT/scripts/install.sh"
