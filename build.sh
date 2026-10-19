#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TokenUsageDisplay"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "🔨 Building $APP_NAME..."
cd "$PROJECT_DIR"

# Build in release mode. CLT 27's SDK currently omits the SwiftUIMacros plugin;
# the last 26.x SDK present on this machine builds the same macOS 14+ package.
# SDKROOT also covers SwiftPM manifest compilation; --sdk alone only covers targets.
SWIFT_BUILD_ARGS=(build -c release)
SWIFT_CACHE_PATH="$PROJECT_DIR/.build/spm-cache"
CLANG_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
mkdir -p "$SWIFT_CACHE_PATH" "$CLANG_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH"
if [[ -n "${TOKENUSAGE_SWIFT_SDK:-}" ]]; then
    export SDKROOT="$TOKENUSAGE_SWIFT_SDK"
    SWIFT_BUILD_ARGS+=("--sdk" "$TOKENUSAGE_SWIFT_SDK")
elif [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    SWIFT_BUILD_ARGS+=("--sdk" "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
fi

swift "${SWIFT_BUILD_ARGS[@]}" --cache-path "$SWIFT_CACHE_PATH"

echo "📦 Creating .app bundle..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$BUILD_DIR/release/$APP_NAME" "$MACOS_DIR/"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/"

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc sign the bundle so ServiceManagement (launch at login) gets a
# stable code identity tied to the bundle identifier across rebuilds.
codesign --force --sign - "$APP_BUNDLE"

echo "✅ App bundle created at: $APP_BUNDLE"
echo ""
echo "To run: open '$APP_BUNDLE'"
echo ""
echo "Note: Since this is a menu bar app (LSUIElement=YES), it won't appear in the Dock."
echo "Look for the gauge icon in your menu bar."
echo ""
echo "To quit: Click the menu bar icon → 退出, or run:"
echo "  pkill $APP_NAME"
