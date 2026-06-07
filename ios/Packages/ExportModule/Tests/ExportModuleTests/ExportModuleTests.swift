import CoreGraphics
import XCTest
@testable import ExportModule

final class ExportModuleTests: XCTestCase {

    // MARK: - Helpers

    /// A small opaque RGBA test image.
    private func makeCGImage(width: Int = 8, height: Int = 8) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    // MARK: - Format metadata

    func testFormatMetadata() {
        XCTAssertEqual(ExportFormat.png.fileExtension, "png")
        XCTAssertEqual(ExportFormat.jpeg(quality: 0.9).fileExtension, "jpg")
        XCTAssertEqual(ExportFormat.mp4.fileExtension, "mp4")

        XCTAssertEqual(ExportFormat.png.displayName, "PNG")
        XCTAssertEqual(ExportFormat.jpeg(quality: 0.9).displayName, "JPEG")

        XCTAssertEqual(ExportFormat.png.mediaKind, .image)
        XCTAssertEqual(ExportFormat.jpeg(quality: 0.9).mediaKind, .image)
        XCTAssertEqual(ExportFormat.mp4.mediaKind, .video)

        XCTAssertEqual(ExportFormat.imageFormats.map(\.id), ["jpeg", "png"])
    }

    // MARK: - Encoding

    func testPNGEncodingHasSignature() throws {
        let data = try ImageExportable(cgImage: makeCGImage()).encode(as: .png)
        XCTAssertEqual(Array(data.prefix(8)), pngSignature)
    }

    func testJPEGEncodingHasSOIMarker() throws {
        let data = try ImageExportable(cgImage: makeCGImage()).encode(as: .jpeg(quality: 0.9))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testEncodedPNGRoundTripsToSameDimensions() throws {
        let data = try ImageExportable(cgImage: makeCGImage(width: 12, height: 9)).encode(as: .png)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let decoded = CGImage(
            pngDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        XCTAssertEqual(decoded?.width, 12)
        XCTAssertEqual(decoded?.height, 9)
    }

    func testEncodingImageAsVideoFormatThrows() {
        XCTAssertThrowsError(try ImageExportable(cgImage: makeCGImage()).encode(as: .mp4)) { error in
            XCTAssertEqual(error as? ExportError, .unsupportedFormat(.mp4))
        }
    }

    // MARK: - File producer

    func testFileNameSanitization() {
        XCTAssertEqual(ExportFileProducer.fileName(baseName: "Kiki", format: .jpeg(quality: 0.9)), "Kiki.jpg")
        XCTAssertEqual(ExportFileProducer.fileName(baseName: "a/b:c", format: .png), "abc.png")
        XCTAssertEqual(ExportFileProducer.fileName(baseName: "  ", format: .png), "Kiki.png")
        // An already-extensioned base name doesn't double up.
        XCTAssertEqual(ExportFileProducer.fileName(baseName: "Kiki.png", format: .png), "Kiki.png")
    }

    func testMakeFileWritesCorrectlyNamedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ExportFileProducer().makeFile(
            from: ImageExportable(cgImage: makeCGImage()),
            format: .png,
            baseName: "Kiki",
            in: dir
        )

        XCTAssertEqual(url.lastPathComponent, "Kiki.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(8)), pngSignature)
    }
}
