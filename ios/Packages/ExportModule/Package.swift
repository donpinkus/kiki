// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExportModule",
    platforms: [.iOS(.v17), .macOS(.v11)],
    products: [
        .library(name: "ExportModule", targets: ["ExportModule"]),
    ],
    targets: [
        .target(name: "ExportModule"),
        .testTarget(
            name: "ExportModuleTests",
            dependencies: ["ExportModule"]
        ),
    ]
)
