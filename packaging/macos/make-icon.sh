#!/bin/sh
# ============================================================
#  make-icon.sh - Regenerate ScrcpyPicker's app icons from one
#  square source PNG (defaults to docs/images/logo.png).
#
#  Outputs:
#    packaging/macos/AppIcon.icns      macOS app icon (iconutil)
#    assets/picker.ico                 Windows icon (installer + shortcuts + exe copy)
#    docs/images/app-icon.png          README display image (transparent background)
#
#  Usage:  bash packaging/macos/make-icon.sh [path/to/logo.png]
#  Needs:  swiftc (Xcode Command Line Tools) + iconutil (bundled with macOS).
#          No third-party dependency.
#
#  After regenerating, remember to copy assets/picker.ico over the WPF copy:
#    cp assets/picker.ico packaging/windows/dotnet/src/ScrcpyPicker/Assets/picker.ico
#  Keep this file pure ASCII + LF.
# ============================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="${1:-$REPO_ROOT/docs/images/logo.png}"

if [ ! -f "$SRC" ]; then
  echo "ERROR: source logo not found: $SRC" >&2; exit 1
fi
if [ ! -x /usr/bin/iconutil ]; then
  echo "ERROR: /usr/bin/iconutil not found (needs macOS)" >&2; exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Compiling make-icon (swiftc)..."
swiftc -O -o "$WORK/make-icon" "$SCRIPT_DIR/make-icon.swift"

echo "==> Rendering icons from $SRC"
"$WORK/make-icon" "$SRC" "$REPO_ROOT/assets" "$REPO_ROOT/docs/images" "$WORK/AppIcon.iconset"

echo "==> Packing .icns (iconutil)..."
iconutil -c icns "$WORK/AppIcon.iconset" -o "$SCRIPT_DIR/AppIcon.icns"

echo "==> Done."
echo "    macOS : $SCRIPT_DIR/AppIcon.icns"
echo "    Windows: $REPO_ROOT/assets/picker.ico"
echo "    Docs  : $REPO_ROOT/docs/images/app-icon.png"
echo ""
echo "Remember: cp assets/picker.ico packaging/windows/dotnet/src/ScrcpyPicker/Assets/picker.ico"
