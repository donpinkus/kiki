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
            ],
            resources: [
                // Folder-referenced grayscale brush-stamp PNGs (luminance = coverage).
                // Drop a PNG in here + add a BrushShapeCatalog entry to expose a new shape.
                .copy("Resources/BrushShapes"),
                // Image-based grain tiles (cloned Procreate grains) — see GrainCatalog.
                .copy("Resources/BrushGrains"),
                // Magic wand: pre-compiled SAM 2.1-small Core ML models
                // (apple/coreml-sam2.1-small, Apache 2.0; ~90 MB). Re-fetch with
                // ios/scripts/fetch-sam-models.sh if ever missing.
                .copy("Resources/SAM2"),
            ]
        ),
    ]
)
