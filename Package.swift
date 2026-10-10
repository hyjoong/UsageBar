// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .executable(name: "UsageBarDoctor", targets: ["UsageBarDoctor"])
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarCore"]),
        .executableTarget(name: "UsageBarDoctor", dependencies: ["UsageBarCore"]),
        .testTarget(name: "UsageBarCoreTests", dependencies: ["UsageBarCore"])
    ]
)
