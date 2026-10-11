// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Outbound",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "OutboundCore"),
        .executableTarget(name: "Outbound", dependencies: ["OutboundCore"]),
        .testTarget(name: "OutboundCoreTests", dependencies: ["OutboundCore"])
    ]
)
