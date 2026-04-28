// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CanvasModule", targets: ["CanvasModule"]),
    ],
    dependencies: [
        .package(path: "../StrokeRecognizerModule"),
    ],
    targets: [
        .target(
            name: "CanvasModule",
            dependencies: [
                .product(name: "StrokeRecognizerModule", package: "StrokeRecognizerModule"),
            ]
        ),
    ]
)
