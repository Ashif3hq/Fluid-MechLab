// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FluidMechLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowCore", targets: ["FlowCore"]),
        .library(name: "FlowGPU", targets: ["FlowGPU"]),
        .executable(name: "FluidMechLab", targets: ["FluidMechLab"]),
    ],
    targets: [
        // Pure-Swift physics engine. No UI dependencies, so it also builds and tests on Linux.
        .target(name: "FlowCore"),
        // Metal compute versions of the FlowCore solvers, for real-time simulation on the GPU.
        .target(name: "FlowGPU", dependencies: ["FlowCore"]),
        // Native macOS SwiftUI app.
        .executableTarget(
            name: "FluidMechLab",
            dependencies: ["FlowCore", "FlowGPU"]
        ),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore", "FlowGPU"]),
    ]
)
