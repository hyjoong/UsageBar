// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .executable(name: "UsageBarDoctor", targets: ["UsageBarDoctor"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "UsageBarDoctor", dependencies: ["UsageBarCore"]),
        .testTarget(name: "UsageBarCoreTests", dependencies: ["UsageBarCore"]),
        .testTarget(name: "UsageBarAppTests", dependencies: ["UsageBar"])
    ]
)
