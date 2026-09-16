#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Building Sub2Bar requires macOS and Xcode." >&2
    exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT_DIR/dist}"
BUILD_ARCH="${2:-native}"
ARCH_ARGS=()
case "$BUILD_ARCH" in
    universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) ARCH_ARGS=(--arch "$BUILD_ARCH") ;;
    native) BUILD_ARCH="$(uname -m)"; ARCH_ARGS=(--arch "$BUILD_ARCH") ;;
    *) echo "Architecture must be native, universal, arm64, or x86_64." >&2; exit 1 ;;
esac
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid app version." >&2; exit 1
fi
SCRATCH_DIR="$DESTINATION/build-cache"
APP_DIR="$DESTINATION/Sub2Bar.app"
ARCHIVE_NAME="Sub2Bar-${VERSION}-macOS-${BUILD_ARCH}.zip"

swift build --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_DIR" -c release "${ARCH_ARGS[@]}"
BINARY_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_DIR" -c release "${ARCH_ARGS[@]}" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/Sub2Bar" "$APP_DIR/Contents/MacOS/Sub2Bar"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/MakeIcon.swift" "$DESTINATION/AppIcon.iconset"
iconutil -c icns "$DESTINATION/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# No developer certificate or Admin Key is needed. This is NOT notarization.
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [[ "$BUILD_ARCH" == universal ]]; then
    lipo "$APP_DIR/Contents/MacOS/Sub2Bar" -verify_arch arm64 x86_64
fi
ditto --norsrc --noextattr -c -k --keepParent "$APP_DIR" "$DESTINATION/$ARCHIVE_NAME"
(
    cd "$DESTINATION"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
    shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)
echo "Built: $DESTINATION/$ARCHIVE_NAME"
