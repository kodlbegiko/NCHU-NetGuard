// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetGuardCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NetGuardCore", targets: ["NetGuardCore"])],
    targets: [
        .target(name: "NetGuardCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "NetGuardCoreTests", dependencies: ["NetGuardCore"])
    ]
)
