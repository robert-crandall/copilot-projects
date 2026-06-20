#!/usr/bin/env bash
# Assemble Copilot Projects.app from the SwiftPM build product.
#
#   scripts/build-app.sh            # debug build -> dist/Copilot Projects.app
#   scripts/build-app.sh --release  # release build
#   scripts/build-app.sh --launch   # build then open the app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --debug)   CONFIG="debug" ;;
    --launch)  LAUNCH=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="Copilot Projects"
# Bundle id carries the project name. It is also the UserDefaults domain (saved
# sidebar width, window frame); LegacyDefaults.migrateIfNeeded() copies the old
# domain across on first launch so those survive the rename. macOS keys
# notification authorization to the bundle id, so it re-prompts once.
BUNDLE_ID="com.obvioussean.copilot-projects"
EXE_NAME="copilot-projects"
VERSION="${VERSION:-0.1.0}"

# SwiftPM needs this when the user's global git sets safe.bareRepository=explicit.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES"

cp "$BUILD_DIR/$EXE_NAME" "$MACOS/$EXE_NAME"

# App icon
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Build + bundle the dtach helper (resumability backend) as a universal binary.
DTACH_SRC="$ROOT/vendor/dtach"
if [ -d "$DTACH_SRC" ]; then
  echo "==> building dtach helper (universal)"
  ( cd "$DTACH_SRC"
    [ -f config.h ] || ./configure >/dev/null 2>&1
    clang -O2 -arch arm64 -arch x86_64 -I. -o dtach-universal \
      main.c master.c attach.c )
  if [ -f "$DTACH_SRC/dtach-universal" ]; then
    mkdir -p "$CONTENTS/Helpers"
    cp "$DTACH_SRC/dtach-universal" "$CONTENTS/Helpers/dtach"
    chmod +x "$CONTENTS/Helpers/dtach"
  else
    echo "warning: dtach build failed — resumability will fall back to plain shells"
  fi
fi

# SwiftTerm resource bundle (Metal shaders). Place where Bundle.module looks.
if [ -d "$BUILD_DIR/SwiftTerm_SwiftTerm.bundle" ]; then
  cp -R "$BUILD_DIR/SwiftTerm_SwiftTerm.bundle" "$RES/"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
  echo "warning: codesign failed (notifications may be limited)"

echo "App path:"
echo "  $APP_DIR"

if [ "$LAUNCH" = "1" ]; then
  open "$APP_DIR"
fi
