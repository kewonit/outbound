// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Outbound",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Sparkle keeps copies up to date: signed updates, checked daily, installed while the Mac is idle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "OutboundCore"),
        // Shaders ship as source and are compiled at launch, so they can be edited live while developing.
        .executableTarget(name: "Outbound", dependencies: ["OutboundCore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Shaders")]),
        .testTarget(name: "OutboundCoreTests", dependencies: ["OutboundCore"])
    ]
)
