// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetworkModule",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NetworkModule", targets: ["NetworkModule"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),
    ],
    targets: [
        .target(
            name: "NetworkModule",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "NetworkModuleTests",
            dependencies: ["NetworkModule"]
        ),
    ]
)
