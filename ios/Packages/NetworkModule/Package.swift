// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetworkModule",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NetworkModule", targets: ["NetworkModule"]),
    ],
    targets: [
        .target(name: "NetworkModule"),
        .testTarget(name: "NetworkModuleTests", dependencies: ["NetworkModule"]),
    ]
)
