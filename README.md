# UniBridge (macOS & Windows)

A native dual-pane universal file bridge for transferring files between **macOS / Windows**, **USB / OTG Pendrives**, **Android (MTP & ADB)**, and **iOS (iPhone & iPad)** over USB.

- **macOS App**: Native SwiftUI + `CDeviceBridge` (`Sources/`)
- **Windows App**: Native WPF / .NET 8 (`windows/`)

## Features

- **Computer Folders**: Browse Home, Desktop, Downloads, Documents, Pictures, Movies/Videos, or pin any custom folder.
- **USB & OTG Pendrives / SD Cards**:
  - **macOS**: Auto-detected via `DiskArbitration` with Safe Eject (`⌘E`), NTFS read-only detection, and FAT32 4 GB file-size guards.
  - **Windows**: Auto-detected via `DriveInfo` + WMI USB disk queries and `WM_DEVICECHANGE` hot-plug notifications, with Win32 `DeviceIoControl` Safe Eject and FAT32 4 GB file-size guards.
- **Android**:
  - **File Transfer (MTP)** via `libmtp` (macOS) / Windows Portable Devices `MediaDevices` (Windows) — works without Developer Mode; unlock your phone and choose **File Transfer**.
  - **USB Debugging (ADB)** via bundled `adb` — fast transfers for folders and large files when USB Debugging is enabled.
- **iOS (iPhone & iPad)**:
  - **Media & Photos (`AFC`)** via bundled `libimobiledevice` — access `DCIM` photos/videos, `Downloads`, `Books`, etc. after tapping **Trust This Computer** (with Windows WPD `DCIM` fallback when needed).
  - **App Documents (`House Arrest`)** — transfer files directly into and out of iOS apps that support USB File Sharing (e.g., VLC, Documents, Pages, Keynote, GarageBand).
- **Dual-Pane Transfers**:
  - Copy or Move between **any** pair of connected endpoints (`PC/Mac ↔ Pendrive`, `PC/Mac ↔ Android`, `PC/Mac ↔ iOS`, `Pendrive ↔ Android`, `Pendrive ↔ iOS`, `Android ↔ iOS`, or local folders).
  - Drag & drop across panes or directly from Finder (macOS) / File Explorer (Windows).
  - Real-time progress, speed (`MB/s`), ETA, pause/resume, cancel cleanup, and file conflict resolution (`Replace`, `Keep Both`, `Skip`).

## Download Prebuilt Apps

From the **Releases** page:
- **macOS (Apple Silicon / macOS 14+)**: Download `UniBridge.app.zip`, unzip, drag `UniBridge.app` to `/Applications`, and launch from Applications, Spotlight, or your Dock.
- **Windows (Windows 10 / 11 x64)**: Download `UniBridge-Windows-x64.zip` (self-contained — no separate `.NET` install required), extract it, and run `UniBridge.exe`.

---

## Build from Source — macOS (macOS 14+, Apple Silicon / Homebrew)

### Prerequisites
```bash
brew install libmtp libimobiledevice
brew install --cask android-platform-tools
```

### Run Unit Tests
```bash
swift test --disable-index-store
```

### Build Self-Contained `.app` Bundle
```bash
./scripts/build_app.sh
```
Compiles the release binary, bundles `libmtp`, `libimobiledevice`, `libusb`, `libplist`, `openssl`, and `adb` inside `build/UniBridge.app`, generates `AppIcon.icns`, writes `Info.plist`, and ad-hoc signs the entire bundle.

### Install to `/Applications` & Pin to Dock
```bash
./scripts/install_to_dock.sh
```
Installs `UniBridge.app` into `/Applications/UniBridge.app`, registers it with LaunchServices, and pins it to your macOS Dock.

---

## Build from Source — Windows (Windows 10 / 11 x64, .NET 8 SDK)

### Run Unit Tests
```powershell
dotnet restore windows/UniBridge.sln
dotnet test windows/UniBridge.Tests/UniBridge.Tests.csproj --configuration Release --no-restore
```

### Publish Self-Contained Executable
```powershell
dotnet publish windows/UniBridge.App/UniBridge.App.csproj -c Release -r win-x64 --self-contained true -o publish/UniBridge
```
Automated Windows builds & release packaging run on every push to `main` via [windows-release.yml](.github/workflows/windows-release.yml).
