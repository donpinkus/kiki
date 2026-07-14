import Foundation

/// A recorded (or authored) set of strokes for the BrushHarness to replay — the contract
/// between the iPad stroke recorder (Brush Studio → "Record strokes") and the headless
/// macOS harness (`BrushHarness/README.md`). Strokes are stored in CANVAS-PIXEL space
/// (see `MetalCanvasView.canvasSpaceStroke`), so a fixture replays identically at
/// harness scale 1 regardless of the view size it was recorded at.
public struct BrushFixture: Codable, Sendable {
    public var schema: Int
    /// Optional label; the harness falls back to the filename.
    public var name: String?
    /// Document side (canvas pixels) the strokes were recorded against.
    /// The app's document is 2048² (`MetalCanvasView.documentSide`).
    public var canvasSide: Int?
    public var strokes: [Stroke]

    public init(schema: Int = 1, name: String? = nil, canvasSide: Int? = nil, strokes: [Stroke]) {
        self.schema = schema
        self.name = name
        self.canvasSide = canvasSide
        self.strokes = strokes
    }
}
