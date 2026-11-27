# UniBridge (macOS)

A native macOS SwiftUI dual-pane universal file bridge for transferring files between **macOS**, **USB / OTG Pendrives**, **Android (MTP & ADB)**, and **iOS (iPhone & iPad)** over USB.

## Features

- **macOS**: Browse Home, Desktop, Downloads, Documents, Pictures, Movies, or any chosen Mac folder.
- **USB & OTG Pendrives / SD Cards**: Auto-detected via `DiskArbitration` with Safe Eject (`⌘E`), NTFS read-only detection, and FAT32 4 GB file-size guards.
- **Android**:
  - **File Transfer (MTP)** via bundled `libmtp` — works without Developer Mode; unlock your phone and choose **File Transfer**.
  - **USB Debugging (ADB)** via bundled `adb` — fast transfers for folders and large files when USB Debugging is enabled.
- **iOS (iPhone & iPad)**:
  - **Media & Photos (`AFC`)** via bundled `libimobiledevice` — access `DCIM` photos/videos, `Downloads`, `Books`, etc. after tapping **Trust This Computer**.
  - **App Documents (`House Arrest`)** — transfer files directly into and out of iOS apps that support USB File Sharing (e.g., VLC, Documents, Pages, Keynote, GarageBand).
- **Dual-Pane Transfers**:
  - Copy or Move between **any** pair of connected endpoints (`Mac ↔ Pendrive`, `Mac ↔ Android`, `Mac ↔ iOS`, `Pendrive ↔ Android`, `Pendrive ↔ iOS`, `Android ↔ iOS`, or `Mac ↔ Mac`).
  - Drag & drop across panes or directly from Finder.
  - Real-time progress, speed (`MB/s`), ETA, pause/resume, cancel cleanup, and file conflict resolution (`Replace`, `Keep Both`, `Skip`).

## Download Prebuilt App

Download `UniBridge.app.zip` from the **Releases** page, unzip it, move `UniBridge.app` into `/Applications`, and launch it from Applications, Spotlight, or your Dock.

## Build from Source (macOS 14+, Apple Silicon / Homebrew)

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
