// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pathway",
    platforms: [.macOS(.v15)],
    targets: [
        // Ресурсов у таргета нет намеренно: заготовки документов собираются
        // кодом (OOXMLBuilder). Ресурсный бандл, не доехавший до собранного
        // приложения, ронял процесс через fatalError внутри Bundle.module.
        .target(name: "PathwayCore"),
        .executableTarget(name: "Pathway", dependencies: ["PathwayCore"]),
        .testTarget(name: "PathwayCoreTests", dependencies: ["PathwayCore"]),
    ]
)
