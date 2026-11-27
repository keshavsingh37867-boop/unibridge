import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PendriveTransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Pendrive Transfer") {
            ContentView(state: appState)
        }
        .defaultSize(width: 1220, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder in Left Pane") {
                    appState.promptNewFolder(in: .left)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Folder in Right Pane") {
                    appState.promptNewFolder(in: .right)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(appState.endpoint(for: .right) == nil || appState.endpoint(for: .right)?.isReadOnly == true)
            }

            CommandMenu("Devices") {
                Button("Rescan All Devices & Refresh") {
                    appState.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Swap Left & Right Panes") {
                    appState.swapPanes()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Safe Eject Pendrive") {
                    if appState.endpoint(for: .right)?.platform == .pendrive {
                        appState.ejectPendrive(in: .right)
                    } else if appState.endpoint(for: .left)?.platform == .pendrive {
                        appState.ejectPendrive(in: .left)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(
                    appState.endpoint(for: .right)?.platform != .pendrive &&
                    appState.endpoint(for: .left)?.platform != .pendrive
                )

                Divider()

                Button("Copy Left -> Right") {
                    appState.transferSelected(from: .left, to: .right, mode: .copy)
                }
                .disabled(!appState.canTransferLeftToRight)

                Button("Copy Right -> Left") {
                    appState.transferSelected(from: .right, to: .left, mode: .copy)
                }
                .disabled(!appState.canTransferRightToLeft)
            }
        }
    }
}
