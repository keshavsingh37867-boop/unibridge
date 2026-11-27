#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="UniBridge"
BUNDLE_DIR="$PROJECT_DIR/build/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

SWIFT_EXTRA_ARGS=(--disable-index-store)
if [[ -n "${CLANG_MODULE_CACHE_PATH:-}" ]]; then
  mkdir -p "$CLANG_MODULE_CACHE_PATH"
  SWIFT_EXTRA_ARGS+=(-Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH")
fi
if [[ -n "${SWIFTPM_CACHE_PATH:-}" ]]; then
  mkdir -p "$SWIFTPM_CACHE_PATH"
  SWIFT_EXTRA_ARGS+=(--disable-sandbox --cache-path "$SWIFTPM_CACHE_PATH")
fi

echo "==> Building release binary with SwiftPM..."
cd "$PROJECT_DIR"
swift build -c release "${SWIFT_EXTRA_ARGS[@]}"

BIN_DIR="$(swift build -c release "${SWIFT_EXTRA_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "Error: compiled binary not found at $EXECUTABLE"
  exit 1
fi

echo "==> Creating .app bundle structure at $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Bundle adb helper if present
if [[ -x "/opt/homebrew/bin/adb" ]]; then
  echo "==> Bundling adb helper..."
  cp -L "/opt/homebrew/bin/adb" "$HELPERS_DIR/adb"
  chmod +x "$HELPERS_DIR/adb"
fi

# Bundle all non-system Homebrew dylibs recursively and rewrite install names to @rpath
echo "==> Bundling Homebrew USB libraries (libmtp, libimobiledevice, libusb, libplist, openssl)..."
python3 - "$MACOS_DIR/$APP_NAME" "$FRAMEWORKS_DIR" <<'PY'
import os
import shutil
import subprocess
import sys

main_bin = sys.argv[1]
frameworks_dir = sys.argv[2]

def linked_libs(path):
    out = subprocess.check_output(["otool", "-L", path], text=True)
    libs = []
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" (")[0].strip()
        if dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/"):
            libs.append(dep)
    return libs

copied = {}
queue = [main_bin]
seen_bins = set()

while queue:
    target = queue.pop(0)
    if target in seen_bins:
        continue
    seen_bins.add(target)

    for dep in linked_libs(target):
        real_dep = os.path.realpath(dep)
        base = os.path.basename(real_dep)
        dest = os.path.join(frameworks_dir, base)
        if base not in copied:
            shutil.copy2(real_dep, dest)
            os.chmod(dest, 0o755)
            copied[base] = dest
            queue.append(dest)

# Ensure @rpath on main binary includes @executable_path/../Frameworks
rpath_out = subprocess.check_output(["otool", "-l", main_bin], text=True)
if "@executable_path/../Frameworks" not in rpath_out:
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", main_bin], check=True)

# Rewrite all dylib IDs and dependency references
all_targets = [main_bin] + list(copied.values())
for item in all_targets:
    if item != main_bin:
        subprocess.run(["install_name_tool", "-id", f"@rpath/{os.path.basename(item)}", item], check=True)
    for dep in linked_libs(item):
        real_base = os.path.basename(os.path.realpath(dep))
        if real_base in copied:
            subprocess.run(["install_name_tool", "-change", dep, f"@rpath/{real_base}", item], check=True)

print(f"Bundled {len(copied)} dynamic libraries into Frameworks/")
PY

echo "==> Generating app icon (.icns)..."
SWIFT_INTERP_ARGS=()
if [[ -n "${CLANG_MODULE_CACHE_PATH:-}" ]]; then
  SWIFT_INTERP_ARGS+=(-module-cache-path "$CLANG_MODULE_CACHE_PATH")
fi

swift "${SWIFT_INTERP_ARGS[@]}" - "$RESOURCES_DIR/AppIcon.icns" <<'SWIFT'
import AppKit
import Foundation

let outICNS = CommandLine.arguments[1]

func renderPNG(px: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "IconGen", code: 2)
    }
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = CGFloat(px) * 0.08
    let roundedRect = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(px) * 0.20

    let bgPath = NSBezierPath(roundedRect: roundedRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.11, green: 0.45, blue: 0.96, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.04, green: 0.25, blue: 0.68, alpha: 1.0)
    )
    gradient?.draw(in: bgPath, angle: -45)

    if let symbol = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.46, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(calibratedRed: 0.42, green: 0.93, blue: 0.65, alpha: 1.0)]))
        if let styled = symbol.withSymbolConfiguration(config) {
            let symSize = styled.size
            let targetWidth = CGFloat(px) * 0.56
            let scale = targetWidth / max(symSize.width, symSize.height)
            let drawW = symSize.width * scale
            let drawH = symSize.height * scale
            let drawRect = NSRect(
                x: (CGFloat(px) - drawW) / 2.0,
                y: (CGFloat(px) - drawH) / 2.0,
                width: drawW,
                height: drawH
            )
            styled.draw(in: drawRect)
        }
    }

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3)
    }
    return png
}

let entries: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("icp6", 64),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

var chunks = Data()
for (tag, px) in entries {
    let png = try renderPNG(px: px)
    chunks.append(Data(tag.utf8))
    var len = UInt32(8 + png.count).bigEndian
    withUnsafeBytes(of: &len) { chunks.append(contentsOf: $0) }
    chunks.append(png)
}

var icns = Data("icns".utf8)
var totalLen = UInt32(8 + chunks.count).bigEndian
withUnsafeBytes(of: &totalLen) { icns.append(contentsOf: $0) }
icns.append(chunks)

try icns.write(to: URL(fileURLWithPath: outICNS))
SWIFT

echo "==> Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>UniBridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.keshav.UniBridge</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>UniBridge</string>
    <key>CFBundleDisplayName</key>
    <string>UniBridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>UniBridge needs access to removable USB and OTG drives to browse and transfer your files.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>UniBridge needs access to your Desktop folder when you browse or transfer Desktop files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>UniBridge needs access to your Downloads folder when you browse or transfer Downloads files.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>UniBridge needs access to your Documents folder when you browse or transfer Documents files.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing bundled frameworks, helpers, and .app bundle..."
for f in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$f" ]] && codesign --force --sign - "$f"
done
if [[ -f "$HELPERS_DIR/adb" ]]; then
  codesign --force --sign - "$HELPERS_DIR/adb"
fi
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "==> Done! Self-contained app created at:"
echo "    $BUNDLE_DIR"
