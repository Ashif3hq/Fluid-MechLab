// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FluidMechLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowCore", targets: ["FlowCore"]),
        .executable(name: "FluidMechLab", targets: ["FluidMechLab"]),
    ],
    targets: [
        // Pure-Swift physics engine. No UI dependencies, so it also builds and tests on Linux.
        .target(name: "FlowCore"),
        // Native macOS SwiftUI app.
        .executableTarget(
            name: "FluidMechLab",
            dependencies: ["FlowCore"]
        ),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore"]),
    ]
)
