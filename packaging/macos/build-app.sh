#!/bin/sh
# ============================================================
#  build-app.sh - Assemble ScrcpyPicker.app and zip it for distribution.
#  Run from anywhere; paths resolve relative to this script.
#  Keep this file pure ASCII + LF.
# ============================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- configurable source paths ---
PWSH_SRC="${PWSH_SRC:-$HOME/powershell}"
SCRCPY_SRC="${SCRCPY_SRC:-$HOME/scrcpy-tools}"
APP_VERSION="${APP_VERSION:-1.1.0}"
ARCH="$(uname -m)"   # arm64 or x86_64

# --- output paths ---
BUILD_DIR="$SCRIPT_DIR/staging"
APP="$BUILD_DIR/ScrcpyPicker.app"
DIST_DIR="$SCRIPT_DIR/../dist"
ZIPNAME="ScrcpyPicker-${APP_VERSION}-${ARCH}.zip"

echo "==> Sources: pwsh=$PWSH_SRC  scrcpy=$SCRCPY_SRC  arch=$ARCH"

# --- validate sources exist ---
# NOTE: The macOS build no longer depends on PowerShell - the service layer is
# the Swift implementation under Sources/, compiled into the same binary.
# PWSH_SRC is kept only for the Windows packaging script; unused here.
if [ ! -x "$SCRCPY_SRC/adb" ]; then
  echo "ERROR: adb not found at $SCRCPY_SRC/adb (set SCRCPY_SRC)" >&2; exit 1
fi
if [ ! -x "$SCRCPY_SRC/scrcpy" ]; then
  echo "ERROR: scrcpy not found at $SCRCPY_SRC/scrcpy (set SCRCPY_SRC)" >&2; exit 1
fi

# --- clean and create skeleton ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/tools"


# --- copy tools (scrcpy + adb + companions) ---
echo "==> Copying scrcpy/adb tools..."
cp "$SCRCPY_SRC/adb"              "$APP/Contents/Resources/tools/"
cp "$SCRCPY_SRC/scrcpy"           "$APP/Contents/Resources/tools/"
# scrcpy-server is the jar-like payload scrcpy pushes to device
[ -f "$SCRCPY_SRC/scrcpy-server" ] && cp "$SCRCPY_SRC/scrcpy-server" "$APP/Contents/Resources/tools/"
# Copy any other runtime files scrcpy may need (e.g. lib/ subdirs from tarball)
for f in "$SCRCPY_SRC"/*; do
  base="$(basename "$f")"
  case "$base" in
    adb|scrcpy|scrcpy-server) ;;  # already handled
    *.png|*.1|LICENSE*)    cp "$f" "$APP/Contents/Resources/tools/" ;;
    *) [ -d "$f" ] && cp -R "$f" "$APP/Contents/Resources/tools/" ;;
  esac
done


# --- Info.plist ---
echo "==> Installing Info.plist..."
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"
# Patch version in-place if APP_VERSION differs from template
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true

# --- compile the whole app: SwiftUI window shell + in-process service ---
echo "==> Compiling ScrcpyPicker (SwiftUI + MVVM + native service)..."
SWIFT_MAIN="$SCRIPT_DIR/main.swift"
SWIFT_APP="$SCRIPT_DIR/ScrcpyPicker.swift"
SWIFT_NAVBAR="$SCRIPT_DIR/NavBar.swift"
for f in "$SWIFT_MAIN" "$SWIFT_APP" "$SWIFT_NAVBAR"; do
  if [ ! -f "$f" ]; then echo "ERROR: Swift source not found: $f" >&2; exit 1; fi
done
for d in Sources Sources/ViewModels Sources/Views; do
  if [ ! -d "$SCRIPT_DIR/$d" ]; then
    echo "ERROR: Swift sources not found: $SCRIPT_DIR/$d" >&2; exit 1
  fi
done
swiftc -o "$APP/Contents/MacOS/ScrcpyPicker" \
  "$SWIFT_MAIN" "$SWIFT_APP" "$SWIFT_NAVBAR" "$SCRIPT_DIR"/Sources/*.swift \
  "$SCRIPT_DIR"/Sources/ViewModels/*.swift "$SCRIPT_DIR"/Sources/Views/*.swift \
  -target "$ARCH-apple-macos13.0" \
  -framework Cocoa -O
chmod +x "$APP/Contents/MacOS/ScrcpyPicker"

# --- icon (optional: .icns must be pre-converted from picker.ico) ---
ICNS="$SCRIPT_DIR/AppIcon.icns"
if [ -f "$ICNS" ]; then
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  echo "==> Icon installed."
else
  echo "==> No AppIcon.icns found (skipping; using default). Convert picker.ico via iconutil if desired."
fi

# --- PkgInfo ---
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- package into dist/ zip ---
mkdir -p "$DIST_DIR"
echo "==> Zipping to dist/$ZIPNAME ..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/$ZIPNAME"

echo "==> Done. App at: $APP"
echo "    Zip at:       $DIST_DIR/$ZIPNAME"
echo ""
echo "To test:  open $APP"
echo "First launch from Finder may show Gatekeeper warning; right-click > Open to bypass."
