#!/usr/bin/env bash
# Builds dist/Vivarium.app from the SwiftPM package.
# The app is intentionally NOT sandboxed: it reads ~/.claude and ~/.codex session
# transcripts and scans processes — App Sandbox would break detection.
# Notarization (future): requires a Developer ID identity + hardened runtime.
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Vivarium"
BUNDLE_ID="com.agiletalk.Vivarium"
MIN_SYSTEM_VERSION="14.0"
VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_CACHE="$DIST_DIR/AppIcon.icns"

mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

CONFIG="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIG="debug"
fi

swift build -c "$CONFIG"
BUILD_BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Icon: regenerate only when the generator script changed.
ICON_STAMP="$DIST_DIR/.icon-stamp"
GEN_HASH="$(shasum -a 256 "$ROOT_DIR/script/generate_icon.swift" | cut -d' ' -f1)"
if [[ ! -f "$ICON_CACHE" || ! -f "$ICON_STAMP" || "$(cat "$ICON_STAMP" 2>/dev/null)" != "$GEN_HASH" ]]; then
  ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  swift "$ROOT_DIR/script/generate_icon.swift" "$ICONSET_DIR"
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_CACHE"
  rm -rf "$ICONSET_DIR"
  echo "$GEN_HASH" >"$ICON_STAMP"
fi
cp "$ICON_CACHE" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps TCC grants stable across rebuilds for local use.
codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" "$@"
}

case "$MODE" in
  run|--debug|debug)
    open_app
    ;;
  --build-only|build-only)
    echo "built $APP_BUNDLE"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    SCRATCH="$(mktemp -d /tmp/vivarium-verify.XXXXXX)"
    STATE_FILE="$SCRATCH/state.json"
    open_app --args --qa-open-aquarium --vivarium-demo --vivarium-state-file "$STATE_FILE"
    sleep 4
    pgrep -x "$APP_NAME" >/dev/null || { echo "FAIL: process not running" >&2; exit 1; }
    echo "OK: process running"

    WIN_ID="$(swift "$ROOT_DIR/script/windowid.swift" "$APP_NAME" || true)"
    if [[ -n "$WIN_ID" ]]; then
      SHOT="$SCRATCH/verify.png"
      if screencapture -x -l "$WIN_ID" "$SHOT" 2>/dev/null && [[ -s "$SHOT" ]]; then
        SIZE=$(stat -f%z "$SHOT")
        if [[ "$SIZE" -gt 20000 ]]; then
          echo "OK: screenshot $SHOT ($SIZE bytes)"
        else
          echo "WARN: screenshot suspiciously small ($SIZE bytes): $SHOT" >&2
        fi
      else
        echo "WARN: screencapture failed (Screen Recording permission?)" >&2
      fi
    else
      echo "FAIL: aquarium window not found" >&2
      pkill -x "$APP_NAME" || true
      exit 1
    fi

    sleep 3
    if [[ -s "$STATE_FILE" ]]; then
      echo "OK: state file written"
    else
      echo "WARN: state file not written yet (demo mode suppresses persistence)" >&2
    fi
    pkill -x "$APP_NAME" || true
    echo "verify passed — artifacts in $SCRATCH"
    ;;
  *)
    echo "usage: $0 [run|--debug|--build-only|--logs|--verify]" >&2
    exit 2
    ;;
esac
