#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/build/UniBridge.app"
DEST_APP="/Applications/UniBridge.app"
OLD_APP="/Applications/PendriveTransfer.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Building UniBridge.app first..."
  "$PROJECT_DIR/scripts/build_app.sh"
fi

echo "==> Stopping any running instance before updating..."
for proc in PendriveTransfer UniBridge; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    pkill -x "$proc" || true
    sleep 1
  fi
done

if [[ -d "$OLD_APP" ]]; then
  echo "==> Removing previous PendriveTransfer.app..."
  rm -rf "$OLD_APP"
fi

echo "==> Installing UniBridge.app to $DEST_APP..."
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "==> Registering with macOS LaunchServices..."
  "$LSREGISTER" -f "$DEST_APP"
fi

echo "==> Updating macOS Dock..."
python3 - "$DEST_APP" <<'PY'
import plistlib
import subprocess
import sys

dest_app = sys.argv[1]
raw = subprocess.check_output(["defaults", "export", "com.apple.dock", "-"])
dock = plistlib.loads(raw) if raw else {}
persistent = dock.get("persistent-apps", [])

if not isinstance(persistent, list):
    persistent = []

filtered = []
has_unibridge = False
for entry in persistent:
    url_str = ""
    if isinstance(entry, dict):
        url_str = entry.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")
    if "PendriveTransfer.app" in url_str:
        continue
    if "UniBridge.app" in url_str:
        has_unibridge = True
    filtered.append(entry)

if dock:
    if not has_unibridge:
        filtered.append({
            "tile-data": {
                "file-data": {
                    "_CFURLString": f"file://{dest_app}/",
                    "_CFURLStringType": 15,
                }
            },
            "tile-type": "file-tile",
        })
    dock["persistent-apps"] = filtered
    subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(dock), check=True)
    subprocess.run(["killall", "Dock"], check=True)
    print("Pinned UniBridge to macOS Dock.")
else:
    if not subprocess.run(["defaults", "read", "com.apple.dock", "persistent-apps"], capture_output=True, text=True).stdout.find("UniBridge.app") >= 0:
        subprocess.run([
            "defaults", "write", "com.apple.dock", "persistent-apps", "-array-add",
            f'<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>{dest_app}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>'
        ], check=True)
        subprocess.run(["killall", "Dock"], check=True)
PY

echo "==> Installed! You can now launch UniBridge from your Dock, /Applications, or Spotlight."
