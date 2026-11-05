// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Debut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "debut", targets: ["debut"]),
    ],
    targets: [
        .target(name: "DebutCore"),
        .target(name: "DebutSystem", dependencies: ["DebutCore"]),
        .executableTarget(name: "debut", dependencies: ["DebutCore", "DebutSystem"]),
        .testTarget(name: "DebutCoreTests", dependencies: ["DebutCore"]),
    ],
    swiftLanguageModes: [.v5]
)
