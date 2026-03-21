// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CanvasModule", targets: ["CanvasModule"]),
    ],
    targets: [
        .target(name: "CanvasModule"),
    ]
)
