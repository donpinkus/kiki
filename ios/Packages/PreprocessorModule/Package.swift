// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PreprocessorModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PreprocessorModule", targets: ["PreprocessorModule"]),
    ],
    targets: [
        .target(name: "PreprocessorModule", path: "Sources"),
        .testTarget(name: "PreprocessorModuleTests", dependencies: ["PreprocessorModule"], path: "Tests"),
    ]
)
