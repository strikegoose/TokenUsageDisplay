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

# Build in release mode
swift build -c release

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
