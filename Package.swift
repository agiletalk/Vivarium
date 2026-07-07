// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vivarium",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VivariumCore", targets: ["VivariumCore"]),
        .library(name: "VivariumDetect", targets: ["VivariumDetect"]),
        .executable(name: "Vivarium", targets: ["Vivarium"]),
    ],
    targets: [
        .target(name: "VivariumCore"),
        .target(name: "VivariumDetect", dependencies: ["VivariumCore"]),
        .executableTarget(name: "Vivarium", dependencies: ["VivariumCore", "VivariumDetect"]),
        .testTarget(name: "VivariumCoreTests", dependencies: ["VivariumCore"]),
        .testTarget(name: "VivariumDetectTests", dependencies: ["VivariumDetect"]),
    ]
)
