// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StrokeRecognizerModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StrokeRecognizerModule", targets: ["StrokeRecognizerModule"]),
    ],
    targets: [
        .target(name: "StrokeRecognizerModule"),
        .testTarget(
            name: "StrokeRecognizerModuleTests",
            dependencies: ["StrokeRecognizerModule"]
        ),
    ]
)
