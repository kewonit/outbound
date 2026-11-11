// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Developer controls are compiled into debug builds and into dev builds (scripts/build-app.sh dev), never a release.
var devSettings: [SwiftSetting] = [.define("DEV", .when(configuration: .debug))]
if ProcessInfo.processInfo.environment["OUTBOUND_DEV"] == "1" { devSettings = [.define("DEV")] }

let package = Package(
    name: "Outbound",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle keeps copies up to date: signed updates, checked daily, installed while the Mac is idle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "OutboundCore"),
        // Shaders ship as source and are compiled at launch, so they can be edited live while developing.
        .executableTarget(name: "Outbound", dependencies: ["OutboundCore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Shaders")], swiftSettings: devSettings),
        // Runs the shaders on the GPU, next to a frozen copy of how they shipped. Reads its .metal files from the
        // source tree.
        .testTarget(name: "ShaderTests", dependencies: ["Outbound", "OutboundCore"],
                    exclude: ["Probes.metal", "Shipped"])
    ]
)

// The tests live only on the maintainer's Mac, so the package declares them only when they are there.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/OutboundCoreTests") {
    package.targets.append(.testTarget(name: "OutboundCoreTests", dependencies: ["OutboundCore"]))
}
