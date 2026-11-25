// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetGuardCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetGuardCore", targets: ["NetGuardCore"]),
        .library(name: "NetGuardObservation", targets: ["NetGuardObservation"]),
        .library(name: "NetGuardWorkflow", targets: ["NetGuardWorkflow"]),
        .library(name: "NetGuardRecovery", targets: ["NetGuardRecovery"]),
        .library(name: "NetGuardProvider", targets: ["NetGuardProvider"]),
        .library(name: "NetGuardTraffic", targets: ["NetGuardTraffic"])
    ],
    targets: [
        .target(name: "NetGuardObservation"),
        .target(name: "NetGuardWorkflow"),
        .target(name: "NetGuardRecovery"),
        .target(name: "NetGuardProvider"),
        .target(name: "NetGuardTraffic"),
        .target(name: "NetGuardCore", dependencies: ["NetGuardObservation", "NetGuardWorkflow", "NetGuardRecovery", "NetGuardProvider", "NetGuardTraffic"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "NetGuardCoreTests", dependencies: ["NetGuardCore"]),
        .testTarget(name: "NetGuardObservationTests", dependencies: ["NetGuardObservation"]),
        .testTarget(name: "NetGuardWorkflowTests", dependencies: ["NetGuardWorkflow"]),
        .testTarget(name: "NetGuardRecoveryTests", dependencies: ["NetGuardRecovery"]),
        .testTarget(name: "NetGuardProviderTests", dependencies: ["NetGuardProvider"]),
        .testTarget(name: "NetGuardTrafficTests", dependencies: ["NetGuardTraffic"])
    ]
)
