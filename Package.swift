// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetGuardCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetGuardCore", targets: ["NetGuardCore"]),
        .library(name: "NetGuardObservation", targets: ["NetGuardObservation"]),
        .library(name: "NetGuardWorkflow", targets: ["NetGuardWorkflow"])
    ],
    targets: [
        .target(name: "NetGuardObservation"),
        .target(name: "NetGuardWorkflow"),
        .target(name: "NetGuardCore", dependencies: ["NetGuardObservation", "NetGuardWorkflow"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "NetGuardCoreTests", dependencies: ["NetGuardCore"]),
        .testTarget(name: "NetGuardObservationTests", dependencies: ["NetGuardObservation"]),
        .testTarget(name: "NetGuardWorkflowTests", dependencies: ["NetGuardWorkflow"])
    ]
)
