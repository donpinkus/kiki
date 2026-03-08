// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ResultModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ResultModule", targets: ["ResultModule"]),
    ],
    targets: [
        .target(name: "ResultModule", path: "Sources"),
        .testTarget(name: "ResultModuleTests", dependencies: ["ResultModule"], path: "Tests"),
    ]
)
