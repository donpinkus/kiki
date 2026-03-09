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
        .target(name: "SchedulerModule", dependencies: [
            .product(name: "NetworkModule", package: "NetworkModule"),
        ]),
        .testTarget(name: "SchedulerModuleTests", dependencies: ["SchedulerModule"]),
    ]
)
