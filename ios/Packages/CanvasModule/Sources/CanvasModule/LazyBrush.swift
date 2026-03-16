import CoreGraphics

struct LazyBrush {

    // MARK: - Properties

    var radius: CGFloat
    private(set) var position: CGPoint = .zero

    // MARK: - Public API

    /// Resets the brush position to the given point (call on touchesBegan).
    mutating func reset(to point: CGPoint) {
        position = point
    }

    /// Moves the brush toward the target point. Returns `true` if the brush moved.
    mutating func update(toward target: CGPoint) -> Bool {
        guard radius > 0 else {
            position = target
            return true
        }

        let dx = target.x - position.x
        let dy = target.y - position.y
        let distance = hypot(dx, dy)

        guard distance > radius else { return false }

        let excess = distance - radius
        position.x += dx * (excess / distance)
        position.y += dy * (excess / distance)
        return true
    }
}
