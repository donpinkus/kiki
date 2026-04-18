import UIKit

// MARK: - Layer Info

/// Metadata for a single canvas layer (name, visibility). The actual texture
/// is stored by index on `CanvasRenderer`.
public struct LayerInfo: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool

    public init(id: UUID = UUID(), name: String, isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
    }
}

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
    public var opacity: CGFloat
    /// Pressure-to-width gamma curve. <1 = heavy feel (wider early), >1 = light feel (narrow early).
    public var pressureGamma: CGFloat
    /// How much stroke opacity varies with average pressure (0 = constant, 1 = fully pressure-driven).
    public var pressureOpacity: CGFloat
    /// Path stabilization strength (0 = raw input, higher = smoother/laggier).
    public var streamline: CGFloat
    /// Start taper distance in screen points.
    public var taperIn: CGFloat
    /// End taper distance in screen points.
    public var taperOut: CGFloat
    /// How much Apple Pencil tilt widens the stroke (0 = none, 1 = dramatic).
    public var tiltSensitivity: CGFloat

    public init(
        color: CodableColor,
        baseWidth: CGFloat,
        opacity: CGFloat = 1.0,
        pressureGamma: CGFloat = 0.7,
        pressureOpacity: CGFloat = 0.0,
        streamline: CGFloat = 0.0,
        taperIn: CGFloat = 0.0,
        taperOut: CGFloat = 0.0,
        tiltSensitivity: CGFloat = 0.0
    ) {
        self.color = color
        self.baseWidth = baseWidth
        self.opacity = opacity
        self.pressureGamma = pressureGamma
        self.pressureOpacity = pressureOpacity
        self.streamline = streamline
        self.taperIn = taperIn
        self.taperOut = taperOut
        self.tiltSensitivity = tiltSensitivity
    }

    public static let defaultPen = BrushConfig(color: .black, baseWidth: 5, pressureGamma: 0.7)

    /// Valid width range for the pen and eraser tools.
    public static let widthRange: ClosedRange<CGFloat> = 1...100

    /// Compute effective stroke width for a given pressure and tilt.
    public func effectiveWidth(force: CGFloat, altitude: CGFloat = .pi / 2) -> CGFloat {
        var width = baseWidth * pow(max(force, 0.01), pressureGamma)
        if tiltSensitivity > 0 {
            let tiltFactor = 1.0 + tiltSensitivity * (1.0 - altitude / (.pi / 2)) * 2.0
            width *= tiltFactor
        }
        return width
    }

    /// Multiplier for base opacity based on average stroke pressure.
    public func pressureAlpha(force: CGFloat) -> CGFloat {
        let pa = pow(max(force, 0.01), 0.7)
        return 1.0 - pressureOpacity + pressureOpacity * pa
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case color, baseWidth, opacity, pressureGamma, pressureOpacity
        case streamline, taperIn, taperOut, tiltSensitivity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(CodableColor.self, forKey: .color)
        baseWidth = try container.decode(CGFloat.self, forKey: .baseWidth)
        pressureGamma = try container.decode(CGFloat.self, forKey: .pressureGamma)
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
        pressureOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .pressureOpacity) ?? 0.0
        streamline = try container.decodeIfPresent(CGFloat.self, forKey: .streamline) ?? 0.0
        taperIn = try container.decodeIfPresent(CGFloat.self, forKey: .taperIn) ?? 0.0
        taperOut = try container.decodeIfPresent(CGFloat.self, forKey: .taperOut) ?? 0.0
        tiltSensitivity = try container.decodeIfPresent(CGFloat.self, forKey: .tiltSensitivity) ?? 0.0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(baseWidth, forKey: .baseWidth)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(pressureGamma, forKey: .pressureGamma)
        try container.encode(pressureOpacity, forKey: .pressureOpacity)
        try container.encode(streamline, forKey: .streamline)
        try container.encode(taperIn, forKey: .taperIn)
        try container.encode(taperOut, forKey: .taperOut)
        try container.encode(tiltSensitivity, forKey: .tiltSensitivity)
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
    case lasso
}

// MARK: - Canvas Action (Legacy Undo)

/// Undoable action type used by the legacy `DrawingCanvasView` (CGBitmapContext engine).
/// Not used by the current Metal engine (`MetalCanvasView`), which uses per-layer
/// bitmap snapshots instead.
public enum CanvasAction {
    case stroke(Stroke)
    case erase(preEraseSnapshot: CGImage, postEraseSnapshot: CGImage)
    case lineartSwap(
        prevStrokes: [Stroke], prevPersistent: CGImage?, prevBaseImage: CGImage?,
        prevBackground: UIImage?, newBackground: UIImage?
    )
    case clear(
        prevStrokes: [Stroke], prevPersistent: CGImage?, prevBaseImage: CGImage?,
        prevBackground: UIImage?
    )
    case lassoMove(preMoveSnapshot: CGImage?, postMoveSnapshot: CGImage?)
}
