// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Outbound",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "OutboundCore"),
        // Shaders ship as source and are compiled at launch, so they can be edited live while developing.
        .executableTarget(name: "Outbound", dependencies: ["OutboundCore"], resources: [.copy("Shaders")]),
        .testTarget(name: "OutboundCoreTests", dependencies: ["OutboundCore"])
    ]
)
