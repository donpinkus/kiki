import UIKit

// MARK: - Stroke Point

/// Per-point data captured from Apple Pencil during a stroke.
public struct StrokePoint: Codable, Sendable {
    public var position: CGPoint
    public var force: CGFloat       // 0–1 normalized
    public var altitude: CGFloat    // radians: 0 = flat, π/2 = perpendicular
    public var timestamp: TimeInterval

    public init(position: CGPoint, force: CGFloat, altitude: CGFloat, timestamp: TimeInterval) {
        self.position = position
        self.force = force
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

// MARK: - Codable Color

/// RGBA color wrapper that's Codable and Sendable for brush serialization.
public struct CodableColor: Codable, Sendable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = CodableColor(red: 0, green: 0, blue: 0)
    public static let white = CodableColor(red: 1, green: 1, blue: 1)

    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Brush Configuration

/// Configures how a brush stroke is rendered.
public struct BrushConfig: Codable, Sendable {
    public var color: CodableColor
    public var baseWidth: CGFloat
    /// Pressure-to-width gamma curve. <1 = heavy feel (wider early), >1 = light feel (narrow early).
    public var pressureGamma: CGFloat

    public init(color: CodableColor, baseWidth: CGFloat, pressureGamma: CGFloat) {
        self.color = color
        self.baseWidth = baseWidth
        self.pressureGamma = pressureGamma
    }

    public static let defaultPen = BrushConfig(color: .black, baseWidth: 5, pressureGamma: 0.7)

    /// Valid width range for the pen and eraser tools.
    public static let widthRange: ClosedRange<CGFloat> = 1...100

    /// Compute effective stroke width for a given pressure value.
    public func effectiveWidth(force: CGFloat) -> CGFloat {
        baseWidth * pow(max(force, 0.01), pressureGamma)
    }
}

// MARK: - Stroke

/// A complete stroke: a sequence of points with a brush configuration.
public struct Stroke: Codable, Sendable, Identifiable {
    public let id: UUID
    public var points: [StrokePoint]
    public var brush: BrushConfig

    public init(id: UUID = UUID(), points: [StrokePoint] = [], brush: BrushConfig = .defaultPen) {
        self.id = id
        self.points = points
        self.brush = brush
    }
}

// MARK: - Tool State

/// The currently active drawing tool.
public enum ToolState: Sendable {
    case brush(BrushConfig)
    case eraser(width: CGFloat)
}

// MARK: - Canvas Action (Undo)

/// An undoable action on the canvas.
public enum CanvasAction {
    case stroke(Stroke)
    case erase(preEraseSnapshot: CGImage)
    /// Lineart swap: stores previous state to undo, and the new background to redo.
    case lineartSwap(
        prevStrokes: [Stroke], prevPersistent: CGImage?, prevBackground: UIImage?,
        newBackground: UIImage?
    )
    /// Clear: stores previous state to undo. Redo just clears everything.
    case clear(prevStrokes: [Stroke], prevPersistent: CGImage?, prevBackground: UIImage?)
}
