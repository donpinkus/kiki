import SwiftUI

/// Decorative rainbow particle field rendered on the result pane during
/// pod warming. While `isEmitting` is true, particles spawn from random
/// points along the bottom and drift upward with a slight arc, fading as
/// they rise. Lets the user *do* something fun during the 90s cold start
/// — drawing on the canvas flips `isEmitting`, which makes the result
/// pane respond visibly even before the AI is ready.
public struct ParticleField: View {
    public let isEmitting: Bool

    @State private var particles: [Particle] = []
    @State private var lastSpawn: TimeInterval = 0

    public init(isEmitting: Bool) {
        self.isEmitting = isEmitting
    }

    public var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                Canvas { gc, _ in
                    for particle in particles {
                        let age = now - particle.birthTime
                        guard age < particle.lifetime else { continue }
                        let t = age / particle.lifetime
                        let opacity = max(0, 1.0 - t)
                        let pos = particle.position(at: age)
                        let radius = particle.radius * (1.0 - t * 0.4)
                        var ctx = gc
                        ctx.opacity = opacity
                        ctx.addFilter(.blur(radius: 1.5))
                        let rect = CGRect(
                            x: pos.x - radius,
                            y: pos.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color(hue: particle.hue, saturation: 0.85, brightness: 1.0))
                        )
                    }
                }
                .blendMode(.plusLighter)
                .onChange(of: context.date) { _, _ in
                    tick(now: now, in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tick(now: TimeInterval, in size: CGSize) {
        // Cull dead particles.
        particles.removeAll { now - $0.birthTime >= $0.lifetime }

        // Spawn while drawing — capped to ~40 spawns/sec to keep Canvas cheap.
        guard isEmitting, now - lastSpawn > 0.025 else { return }
        for _ in 0..<2 {
            particles.append(.spawn(in: size, at: now))
        }
        lastSpawn = now
    }
}

private struct Particle {
    let origin: CGPoint
    let velocity: CGVector
    let hue: Double
    let birthTime: TimeInterval
    let lifetime: TimeInterval
    let radius: CGFloat

    func position(at age: TimeInterval) -> CGPoint {
        // Slight downward acceleration produces an arc-y rise-and-fall.
        CGPoint(
            x: origin.x + velocity.dx * age,
            y: origin.y + velocity.dy * age + 30 * age * age
        )
    }

    static func spawn(in size: CGSize, at time: TimeInterval) -> Particle {
        Particle(
            origin: CGPoint(
                x: .random(in: 0...size.width),
                y: .random(in: size.height * 0.65 ... size.height)
            ),
            velocity: CGVector(
                dx: .random(in: -50...50),
                dy: .random(in: -200 ... -90)
            ),
            hue: .random(in: 0...1),
            birthTime: time,
            lifetime: .random(in: 1.6...2.4),
            radius: .random(in: 3...6)
        )
    }
}
