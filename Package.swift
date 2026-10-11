// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Outbound",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")
    ],
    targets: [
        .target(name: "OutboundCore"),
        .executableTarget(name: "Outbound", dependencies: [
            "OutboundCore",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
        ]),
        .testTarget(name: "OutboundCoreTests", dependencies: ["OutboundCore"])
    ]
)
