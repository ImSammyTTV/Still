// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Still", targets: ["Still"])],
    targets: [
        .target(name: "StillCore"),
        .executableTarget(name: "Still", dependencies: ["StillCore"]),
        .testTarget(name: "StillCoreTests", dependencies: ["StillCore"])
    ]
)
