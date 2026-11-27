// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "UniBridgeCore",
            targets: ["UniBridgeCore"]
        ),
        .executable(
            name: "UniBridge",
            targets: ["UniBridge"]
        )
    ],
    targets: [
        .target(
            name: "CDeviceBridge",
            dependencies: [],
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/libmtp/include",
                    "-I/opt/homebrew/opt/libimobiledevice/include",
                    "-I/opt/homebrew/opt/libplist/include",
                    "-I/opt/homebrew/opt/libusbmuxd/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/libmtp/lib",
                    "-L/opt/homebrew/opt/libimobiledevice/lib",
                    "-L/opt/homebrew/opt/libplist/lib"
                ]),
                .linkedLibrary("mtp"),
                .linkedLibrary("imobiledevice-1.0"),
                .linkedLibrary("plist-2.0")
            ]
        ),
        .target(
            name: "UniBridgeCore",
            dependencies: ["CDeviceBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "UniBridge",
            dependencies: ["UniBridgeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"
                ])
            ]
        ),
        .testTarget(
            name: "UniBridgeTests",
            dependencies: ["UniBridgeCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"
                ])
            ]
        )
    ]
)
