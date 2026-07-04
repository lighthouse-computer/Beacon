// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [
        // macOS 13 (Ventura) — required for SMAppService.mainApp and modern SwiftUI.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Beacon"
        ),
        .testTarget(
            name: "BeaconTests",
            dependencies: ["Beacon"]
        ),
    ]
)
