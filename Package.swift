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
        // Work log (daily journal) engine. Depends on Foundation only so it can move to its own app later.
        .target(name: "WorkLogCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarCore", "WorkLogCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "UsageBarDoctor", dependencies: ["UsageBarCore", "WorkLogCore"]),
        .testTarget(name: "UsageBarCoreTests", dependencies: ["UsageBarCore"]),
        .testTarget(name: "WorkLogCoreTests", dependencies: ["WorkLogCore"]),
        .testTarget(name: "UsageBarAppTests", dependencies: ["UsageBar"])
    ]
)
