#!/usr/bin/env bash
# Builds Swift Saber and packages it as a signed macOS app bundle.
#   ./Scripts/build-app.sh            -> build/Swift Saber.app
#   ./Scripts/build-app.sh --run      -> build and launch
#   ./Scripts/build-app.sh --install  -> build and copy to /Applications
# Requires macOS 14+ and Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="Swift Saber"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Compiling (release)…"
swift build -c release --product SwiftSaber
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SwiftSaber" "$APP/Contents/MacOS/SwiftSaber"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Rendering app icon…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
if "$APP/Contents/MacOS/SwiftSaber" --export-iconset "$ICONSET" && command -v iconutil >/dev/null; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "  (icon conversion skipped)"
fi
rm -rf "$ICONSET"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built: $APP"

case "${1:-}" in
  --run)
    open "$APP"
    ;;
  --install)
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "✓ Installed to /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    ;;
esac
