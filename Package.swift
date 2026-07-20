// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pathway",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PathwayCore"),
        .executableTarget(name: "Pathway", dependencies: ["PathwayCore"]),
        .testTarget(name: "PathwayCoreTests", dependencies: ["PathwayCore"]),
    ]
)
