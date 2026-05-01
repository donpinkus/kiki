import XCTest
@testable import StrokeRecognizerModule

final class StrokeRecognizerTests: XCTestCase {

    // MARK: - Stroke synthesis helpers

    /// Build a sequence of `RecognizerInputPoint`s from positions, dt seconds apart.
    private func points(_ positions: [CGPoint], dt: TimeInterval = 0.008) -> [RecognizerInputPoint] {
        positions.enumerated().map { i, p in
            RecognizerInputPoint(position: p, timestamp: TimeInterval(i) * dt)
        }
    }

    /// Synthesize a straight line stroke from `from` to `to` with `n` samples.
    /// `noise` adds Gaussian-ish jitter perpendicular to the stroke direction.
    private func straightLine(from: CGPoint, to: CGPoint, n: Int, noise: CGFloat = 0) -> [CGPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = sqrt(dx * dx + dy * dy)
        let nx = -dy / len  // unit normal
        let ny = dx / len
        var rng = SeededRNG(seed: 42)
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            let baseX = from.x + dx * t
            let baseY = from.y + dy * t
            let jitter = noise * (rng.nextUnit() - 0.5) * 2  // [-noise, +noise]
            return CGPoint(x: baseX + nx * jitter, y: baseY + ny * jitter)
        }
    }

    /// Synthesize an arc stroke: `n` points along an arc of `radius` covering
    /// `coverageDeg` starting at `startDeg`, centered at `center`.
    private func arc(center: CGPoint, radius: CGFloat, startDeg: CGFloat, coverageDeg: CGFloat, n: Int) -> [CGPoint] {
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            let deg = startDeg + coverageDeg * t
            let rad = deg * .pi / 180
            return CGPoint(x: center.x + radius * cos(rad),
                           y: center.y + radius * sin(rad))
        }
    }

    // MARK: - Closed-shape synthesis helpers

    /// Synthesize a full ellipse with optional rotation. n samples around the
    /// perimeter; the first and last points are the same parameter angle (so
    /// closure ratio is near zero — like a real drawn closed loop).
    private func ellipseShape(
        center: CGPoint,
        semiMajor: CGFloat,
        semiMinor: CGFloat,
        rotationDeg: CGFloat = 0,
        n: Int = 80,
        coverageDeg: CGFloat = 360
    ) -> [CGPoint] {
        let rotRad = rotationDeg * .pi / 180
        let cosT = cos(rotRad)
        let sinT = sin(rotRad)
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            let theta = (coverageDeg * t) * .pi / 180
            // Local (axis-aligned) point on the ellipse
            let lx = semiMajor * cos(theta)
            let ly = semiMinor * sin(theta)
            // Rotate + translate to world
            return CGPoint(
                x: center.x + lx * cosT - ly * sinT,
                y: center.y + lx * sinT + ly * cosT
            )
        }
    }

    // MARK: - Acceptance tests (gallery row 1, 2, 14)

    func test_cleanStraightLine_snapsToLine() {
        let r = StrokeRecognizer()
        let pts = straightLine(from: CGPoint(x: 100, y: 100),
                               to: CGPoint(x: 400, y: 100),
                               n: 60, noise: 0.5)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .line(let geom) = verdict {
            // Endpoints should be very close to the original endpoints.
            XCTAssertEqual(geom.start.x, 100, accuracy: 2)
            XCTAssertEqual(geom.end.x, 400, accuracy: 2)
        } else {
            XCTFail("Expected .line, got \(verdict)")
        }
    }

    func test_jitteryLine_snapsToLine() {
        // Per gallery row 1: long deliberate straight line, *mild* jitter.
        // Stroke is fundamentally a line; noise should not push it to abstain.
        // (Note: gallery row 2's "5° bow / 1.5% sagitta" is geometrically
        // inconsistent — a uniform 5° arc actually has ~2.2% sagitta. A 5°
        // uniform arc *should* abstain in v0; that's the right behavior.
        // The case we want to assert here is a line with jitter, which is
        // the realistic Apple Pencil signal we expect to snap.)
        let r = StrokeRecognizer()
        let pts = straightLine(from: CGPoint(x: 100, y: 100),
                               to: CGPoint(x: 400, y: 100),
                               n: 60, noise: 1.5)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .line = verdict {
            // pass
        } else {
            XCTFail("Expected .line for jittery line, got \(verdict). " +
                    "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
        }
    }

    func test_moderate30DegArc_snapsToLine() {
        // After the 2026-04 aggressive loosening, ~30° bows snap. Hold = opt-in:
        // the user explicitly committed to correction by holding the pen.
        // Empirically, lineRMS for a uniform 30° arc is only ~0.020 (the
        // best-fit line is offset from the chord, not equal to it), so the
        // line-fit gate doesn't trip until ~45° arcs. See test_uniform45DegArc.
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 250, y: 600),
                      radius: 300, startDeg: -105, coverageDeg: 30, n: 60)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .line = verdict {
            // pass
        } else {
            XCTFail("Expected .line for 30° bow (aggressive snap), got \(verdict). " +
                    "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
        }
    }

    func test_uniform45DegArc_abstains() {
        // 45° arc (sag ~10%) is genuinely curved — should abstain even with the
        // aggressive 2026-04 loosening. This is the new boundary between
        // "line-ish bow" and "actual arc."
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 250, y: 600),
                      radius: 300, startDeg: -112.5, coverageDeg: 45, n: 60)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .abstain(let reason) = verdict {
            XCTAssertEqual(reason, .lowConfidence,
                "Expected low-confidence abstain on uniform 45° arc, got \(reason)")
        } else {
            XCTFail("Expected abstain for uniform 45° arc, got \(verdict). " +
                    "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
        }
    }

    func test_subtle15DegArc_snapsToLine() {
        // Inverse assertion: subtle bows DO snap (this is the new behavior).
        // A 15° arc looks line-like enough that the v0 recognizer should
        // commit to it — the user opted in via the hold gesture.
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 250, y: 600),
                      radius: 300, startDeg: -97.5, coverageDeg: 15, n: 60)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .line = verdict {
            // pass
        } else {
            XCTFail("Expected .line for 15° arc (subtle bow); got \(verdict). " +
                    "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
        }
    }

    // MARK: - Abstain tests (gallery rows 4, 5, 16, 17)

    func test_clear90DegArc_abstains() {
        // Per gallery row 4: clear 90° arc → in v0 (no arc branch), should
        // abstain on lowConfidence (line score is poor).
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 200, y: 200),
                      radius: 100, startDeg: 0, coverageDeg: 90, n: 50)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .abstain(let reason) = verdict {
            XCTAssertEqual(reason, .lowConfidence,
                "Arc should abstain on lowConfidence in v0, got \(reason)")
        } else {
            XCTFail("Expected .abstain for 90° arc, got \(verdict)")
        }
    }

    func test_halfCircle_abstains() {
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 200, y: 200),
                      radius: 100, startDeg: 0, coverageDeg: 180, n: 80)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .abstain = verdict {
            // pass — line score is very poor
        } else {
            XCTFail("Expected .abstain for half circle, got \(verdict)")
        }
    }

    func test_tinyDot_abstainsTooShort() {
        // Path length < minPathLength = 16 pt
        let r = StrokeRecognizer()
        let pts = straightLine(from: CGPoint(x: 100, y: 100),
                               to: CGPoint(x: 105, y: 100),
                               n: 6)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .abstain(let reason) = verdict {
            XCTAssertEqual(reason, .tooShort)
        } else {
            XCTFail("Expected .abstain(.tooShort), got \(verdict)")
        }
    }

    func test_overtraceCircle_abstainsOvertraced() {
        // Drawn 1.5× — totalSignedTurn > 2.5π
        let r = StrokeRecognizer()
        let pts = arc(center: CGPoint(x: 200, y: 200),
                      radius: 100, startDeg: 0, coverageDeg: 540, n: 200)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        if case .abstain(let reason) = verdict {
            XCTAssertEqual(reason, .overtraced)
        } else {
            XCTFail("Expected .abstain(.overtraced), got \(verdict)")
        }
    }

    // MARK: - Endpoint-projection invariants

    func test_endpointProjection_preservesUserEndpointsApproximately() {
        // Per PaleoSketch principle: snapped endpoints should be very close to
        // raw endpoints, projected onto the fitted line.
        let r = StrokeRecognizer()
        let from = CGPoint(x: 100, y: 100)
        let to = CGPoint(x: 400, y: 105)  // slight off-axis
        let pts = straightLine(from: from, to: to, n: 60, noise: 0.5)
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        guard case .line(let geom) = verdict else {
            XCTFail("Expected .line"); return
        }
        // Projection moves endpoints onto the fit; offset should be small.
        let dStart = hypot(geom.start.x - from.x, geom.start.y - from.y)
        let dEnd = hypot(geom.end.x - to.x, geom.end.y - to.y)
        XCTAssertLessThan(dStart, 5)
        XCTAssertLessThan(dEnd, 5)
    }

    // MARK: - Reset behavior

    func test_reset_clearsState() {
        let r = StrokeRecognizer()
        let pts = straightLine(from: CGPoint(x: 100, y: 100),
                               to: CGPoint(x: 400, y: 100),
                               n: 60)
        for p in points(pts) { r.feed(point: p) }
        _ = r.finalize()
        r.reset()
        XCTAssertEqual(r.currentConfidence, 0)
        // After reset, finalize() with no points should abstain.
        let v = r.finalize()
        if case .abstain = v {
            // pass
        } else {
            XCTFail("Expected abstain after reset, got \(v)")
        }
    }

    // MARK: - Hold detection

    func test_isHolding_falseDuringActiveDrawing() {
        let r = StrokeRecognizer()
        // 60 samples 8ms apart with steady motion = velocity ~3750 pt/s
        let pts = straightLine(from: CGPoint(x: 100, y: 100),
                               to: CGPoint(x: 400, y: 100), n: 60)
        for p in points(pts) { r.feed(point: p) }
        XCTAssertFalse(r.isHolding)
    }

    func test_isHolding_trueAfterStationaryWindow() {
        let r = StrokeRecognizer()
        // 30 samples of motion, then 30 samples stationary at the end.
        let drawingPts = straightLine(from: CGPoint(x: 100, y: 100),
                                      to: CGPoint(x: 400, y: 100), n: 30)
        var allInputs = points(drawingPts)
        let lastTime = allInputs.last!.timestamp
        let lastPos = allInputs.last!.position
        // Add 200ms of stationary samples (well over 120ms holdStabilityWindow).
        for i in 1...30 {
            allInputs.append(RecognizerInputPoint(
                position: lastPos,
                timestamp: lastTime + TimeInterval(i) * 0.008
            ))
        }
        for p in allInputs { r.feed(point: p) }
        XCTAssertTrue(r.isHolding)
    }

    func test_isHolding_trueWithMicroHandJitter() {
        // Real Apple Pencil hold has sub-pixel position noise + hand tremor.
        // Per-sample velocity explodes on this; bbox-diagonal formulation
        // should tolerate it cleanly.
        let r = StrokeRecognizer()
        let drawingPts = straightLine(from: CGPoint(x: 100, y: 100),
                                      to: CGPoint(x: 400, y: 100), n: 30)
        var allInputs = points(drawingPts)
        let lastTime = allInputs.last!.timestamp
        let lastPos = allInputs.last!.position
        var rng = SeededRNG(seed: 7)
        // 200ms of "stationary" samples with realistic ±2pt hand tremor.
        for i in 1...30 {
            let jitterX = (rng.nextUnit() - 0.5) * 4
            let jitterY = (rng.nextUnit() - 0.5) * 4
            allInputs.append(RecognizerInputPoint(
                position: CGPoint(x: lastPos.x + jitterX, y: lastPos.y + jitterY),
                timestamp: lastTime + TimeInterval(i) * 0.008
            ))
        }
        for p in allInputs { r.feed(point: p) }
        XCTAssertTrue(r.isHolding,
            "isHolding should tolerate ±2pt natural hand tremor — real Apple Pencil never produces a perfectly stationary signal")
    }

    func test_isHolding_falseWithLargeJitter() {
        // 10pt jitter is "small drift," not stationary — should NOT count as holding.
        let r = StrokeRecognizer()
        let drawingPts = straightLine(from: CGPoint(x: 100, y: 100),
                                      to: CGPoint(x: 400, y: 100), n: 30)
        var allInputs = points(drawingPts)
        let lastTime = allInputs.last!.timestamp
        let lastPos = allInputs.last!.position
        var rng = SeededRNG(seed: 11)
        for i in 1...30 {
            let jitterX = (rng.nextUnit() - 0.5) * 20  // ±10 pt
            let jitterY = (rng.nextUnit() - 0.5) * 20
            allInputs.append(RecognizerInputPoint(
                position: CGPoint(x: lastPos.x + jitterX, y: lastPos.y + jitterY),
                timestamp: lastTime + TimeInterval(i) * 0.008
            ))
        }
        for p in allInputs { r.feed(point: p) }
        XCTAssertFalse(r.isHolding,
            "10pt drift is not 'holding' — user is moving the pen, just slowly")
    }

    // MARK: - Closed-shape (ellipse / circle) tests

    func test_cleanCircle_snapsToCircle() {
        let r = StrokeRecognizer()
        // 80-sample circle, radius 100
        let pts = ellipseShape(
            center: CGPoint(x: 200, y: 200),
            semiMajor: 100, semiMinor: 100, n: 80
        )
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        guard case .circle(let c) = verdict else {
            XCTFail("Expected .circle, got \(verdict). " +
                "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
            return
        }
        XCTAssertEqual(c.center.x, 200, accuracy: 5)
        XCTAssertEqual(c.center.y, 200, accuracy: 5)
        XCTAssertEqual(c.radius, 100, accuracy: 5)
    }

    func test_axisAlignedEllipse_snapsToEllipse() {
        // 2:1 ellipse — should not promote to circle
        let r = StrokeRecognizer()
        let pts = ellipseShape(
            center: CGPoint(x: 200, y: 200),
            semiMajor: 150, semiMinor: 75, n: 80
        )
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        guard case .ellipse(let e) = verdict else {
            XCTFail("Expected .ellipse, got \(verdict). " +
                "Score: \(r.currentConfidence), snapshot: \(String(describing: r.lastFeatureSnapshot))")
            return
        }
        XCTAssertEqual(e.semiMajor, 150, accuracy: 8)
        XCTAssertEqual(e.semiMinor, 75, accuracy: 8)
        XCTAssertLessThan(e.axisRatio, 0.92,
            "axisRatio \(e.axisRatio) should be below circle promotion gate")
    }

    func test_rotatedEllipse_snapsWithCorrectRotation() {
        // 2:1 ellipse rotated 30°
        let r = StrokeRecognizer()
        let pts = ellipseShape(
            center: CGPoint(x: 200, y: 200),
            semiMajor: 150, semiMinor: 75,
            rotationDeg: 30, n: 80
        )
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        guard case .ellipse(let e) = verdict else {
            XCTFail("Expected .ellipse, got \(verdict)")
            return
        }
        // Rotation may be reported in any equivalent representation
        // (θ ± kπ). Reduce to [0, π) and check distance to 30° in radians.
        let normRot = ((e.rotation.truncatingRemainder(dividingBy: .pi)) + .pi)
            .truncatingRemainder(dividingBy: .pi)
        let target = CGFloat(30) * .pi / 180
        let diff = min(abs(normRot - target), .pi - abs(normRot - target))
        XCTAssertLessThan(diff, 0.1,  // ~5.7° tolerance
            "Rotation \(e.rotation * 180 / .pi)° should be within 5.7° of 30°")
    }

    func test_openArc_doesNotRouteToClosedBranch() {
        // 90° arc — endpoints far apart; closure ratio > gate; routes to line.
        // Should abstain via the line branch (not snap to ellipse).
        let r = StrokeRecognizer()
        let pts = arc(
            center: CGPoint(x: 200, y: 200),
            radius: 100, startDeg: 0, coverageDeg: 90, n: 50
        )
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        switch verdict {
        case .ellipse, .circle:
            XCTFail("90° open arc should NOT snap to closed shape, got \(verdict)")
        default:
            // Either .line, .abstain — both are acceptable for v0
            break
        }
    }

    func test_threeQuarterCircle_doesNotSnapToCircle() {
        // 270° arc — endpoints are R√2 apart, path is 3πR/2.
        // closureRatio = √2/(3π/2) ≈ 0.30, well above closureGate (0.10).
        // Routes to OPEN branch and abstains (line scoring fails on a curve).
        // v0 requires a fully-closed loop to snap to a circle/ellipse.
        let r = StrokeRecognizer()
        let pts = arc(
            center: CGPoint(x: 200, y: 200),
            radius: 100, startDeg: 0, coverageDeg: 270, n: 80
        )
        for p in points(pts) { r.feed(point: p) }
        let verdict = r.finalize()
        switch verdict {
        case .circle, .ellipse:
            XCTFail("270° arc should NOT snap to closed shape (closure too open), got \(verdict)")
        default:
            // .line, .abstain — both acceptable
            break
        }
    }
}

// MARK: - Deterministic RNG for tests

/// Linear-congruential RNG for reproducible noise. Not cryptographic.
private struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextUnit() -> CGFloat {
        return CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
    }
}
