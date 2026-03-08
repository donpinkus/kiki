// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SchedulerModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SchedulerModule", targets: ["SchedulerModule"]),
    ],
    dependencies: [
        .package(path: "../NetworkModule"),
    ],
    targets: [
        .target(
            name: "SchedulerModule",
            dependencies: ["NetworkModule"],
            path: "Sources"
        ),
        .testTarget(name: "SchedulerModuleTests", dependencies: ["SchedulerModule"], path: "Tests"),
    ]
)
