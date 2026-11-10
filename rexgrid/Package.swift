// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RexGrid",
    platforms: [.macOS(.v14)],
    targets: [
        // Model, event parsing, and the boundary to the `rex` CLI. No UI.
        .target(name: "RexGridCore"),
        // The floating panel.
        .executableTarget(name: "RexGrid", dependencies: ["RexGridCore"]),
        .testTarget(name: "RexGridCoreTests", dependencies: ["RexGridCore"]),
    ]
)
