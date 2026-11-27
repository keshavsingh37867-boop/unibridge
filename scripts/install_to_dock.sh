#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/build/PendriveTransfer.app"
DEST_APP="/Applications/PendriveTransfer.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Building PendriveTransfer.app first..."
  "$PROJECT_DIR/scripts/build_app.sh"
fi

echo "==> Stopping any running instance before updating..."
if pgrep -x PendriveTransfer >/dev/null 2>&1; then
  pkill -x PendriveTransfer || true
  sleep 1
fi

echo "==> Installing PendriveTransfer.app to $DEST_APP..."
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "==> Registering with macOS LaunchServices..."
  "$LSREGISTER" -f "$DEST_APP"
fi

echo "==> Checking macOS Dock..."
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "PendriveTransfer.app"; then
  echo "Pendrive Transfer is already pinned in the Dock."
else
  echo "==> Pinning Pendrive Transfer to macOS Dock..."
  defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/PendriveTransfer.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>'
  killall Dock
  echo "Pinned Pendrive Transfer to the Dock."
fi

echo "==> Installed! You can now launch Pendrive Transfer from your Dock, /Applications, or Spotlight."
