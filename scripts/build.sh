#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="EdgeProfileDock"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
STUB_OUT="$BUILD_DIR/LauncherStub"
mkdir -p "$BUILD_DIR"
PACKAGE_STAGE="$(mktemp -d "$BUILD_DIR/.package.XXXXXXXX")"
trap 'find "$PACKAGE_STAGE" -depth -delete' EXIT
SWIFT_SCRATCH="$PACKAGE_STAGE/swift"
STAGED_STUB="$PACKAGE_STAGE/LauncherStub"
COMPILER_TMP="$PACKAGE_STAGE/tmp"
mkdir -p "$COMPILER_TMP"

echo "==> compile LauncherStub"
TMPDIR="$COMPILER_TMP" swiftc -O -framework AppKit -framework Foundation \
  -target arm64-apple-macos14 \
  -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$PACKAGE_STAGE/ModuleCache" \
  -o "$STAGED_STUB" \
  "$ROOT/LauncherStub/main.swift" "$ROOT/EdgeProfileDock/Models.swift"
chmod +x "$STAGED_STUB"

echo "==> swift build (release) EdgeProfileDock"
TMPDIR="$COMPILER_TMP" swift build --scratch-path "$SWIFT_SCRATCH" -c release --product "$APP_NAME"

BIN="$(TMPDIR="$COMPILER_TMP" swift build --scratch-path "$SWIFT_SCRATCH" -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP_DIR"
STAGED_APP="$PACKAGE_STAGE/$APP_NAME.app"
CONTENTS="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/strip -S -o "$MACOS_DIR/$APP_NAME" "$BIN"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$STAGED_STUB" "$RESOURCES_DIR/LauncherStub"
chmod +x "$RESOURCES_DIR/LauncherStub"
cp "$ROOT/EdgeProfileDock/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/EdgeProfileDock/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
bash "$ROOT/scripts/sign_app.sh" "$STAGED_APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$STAGED_APP" "$PACKAGE_STAGE/$APP_NAME.zip"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
mv "$PACKAGE_STAGE/$APP_NAME.zip" "$ZIP_PATH"
mv "$STAGED_STUB" "$STUB_OUT"

echo "==> done"
echo "Stub: $STUB_OUT"
echo "App:  $APP_DIR"
echo "Zip:  $ZIP_PATH"
