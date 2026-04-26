import Foundation
import StrokeRecognizerModule

/// Telemetry-grade lifecycle events emitted by the QuickShape recognizer
/// integration. The app target wires `MetalCanvasView.onSnapEvent` to a
/// closure that forwards these to its analytics backend.
///
/// Payloads carry the recognizer's `FeatureSnapshot` so threshold tuning
/// can be done from real telemetry rather than synthetic gallery data.
public enum SnapEvent {
    /// A snap was committed — the user's stroke has been replaced with a
    /// corrected primitive. Includes the verdict, score, time-since-stroke-start,
    /// and full feature snapshot.
    case committed(SnapCommittedInfo)

    /// The user lifted the pen and no snap was committed. Carries the
    /// abstain reason and feature snapshot for funnel analysis.
    case abstained(SnapAbstainedInfo)

    /// A snap was committed, then undone within `withinSeconds`. Strong
    /// proxy for "the system snapped wrong" — track this rate as the
    /// primary product metric.
    case undoneWithin2s(SnapUndoneInfo)

    /// A preview ghost appeared during the hold window but was canceled
    /// before commit (movement resumed, confidence dropped, etc.).
    case previewCanceled(SnapPreviewCanceledInfo)
}

public struct SnapCommittedInfo {
    public let verdict: String           // "line" for v0
    public let confidence: Double
    public let strokeDurationSec: Double // touchesEnded.timestamp - touchesBegan.timestamp
    public let snapshot: FeatureSnapshot

    public init(verdict: String, confidence: Double, strokeDurationSec: Double, snapshot: FeatureSnapshot) {
        self.verdict = verdict
        self.confidence = confidence
        self.strokeDurationSec = strokeDurationSec
        self.snapshot = snapshot
    }
}

public struct SnapAbstainedInfo {
    public let reason: String            // AbstainReason raw value
    public let confidence: Double
    public let snapshot: FeatureSnapshot?

    public init(reason: String, confidence: Double, snapshot: FeatureSnapshot?) {
        self.reason = reason
        self.confidence = confidence
        self.snapshot = snapshot
    }
}

public struct SnapUndoneInfo {
    public let originalVerdict: String   // typically "line" in v0
    public let elapsedSec: Double        // wall-clock between commit and undo
    public let snapshot: FeatureSnapshot?

    public init(originalVerdict: String, elapsedSec: Double, snapshot: FeatureSnapshot?) {
        self.originalVerdict = originalVerdict
        self.elapsedSec = elapsedSec
        self.snapshot = snapshot
    }
}

public struct SnapPreviewCanceledInfo {
    public let reason: String            // "movement" | "confidence" | "verdict_change"

    public init(reason: String) {
        self.reason = reason
    }
}
