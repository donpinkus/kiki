import Foundation

/// Server-side provisioning state codes. Mirrors the `State` enum in
/// `backend/src/modules/orchestrator/orchestrator.ts`. Backend sends these as
/// raw strings over the WebSocket; iOS maps them to display text locally —
/// backend never emits display strings anymore.
public enum ProvisionState: String, Decodable, Sendable {
    case queued
    case findingGpu = "finding_gpu"
    case creatingPod = "creating_pod"
    case fetchingImage = "fetching_image"
    case warmingModel = "warming_model"
    case connecting
    case ready
    case failed
    case terminated
}

/// Classified reason for a `state == .failed` terminal event. Mirrors
/// `FailureCategory` in `backend/src/modules/orchestrator/errorClassification.ts`.
public enum FailureCategory: String, Decodable, Sendable {
    case spotCapacity = "spot_capacity"
    case podCreateFailed = "pod_create_failed"
    case podBootStall = "pod_boot_stall"
    case podVanished = "pod_vanished"
    case warmModelTimeout = "warm_model_timeout"
    case monthlyCap = "monthly_cap"
    case transientRunpod = "transient_runpod"
    case unknown
}

/// Returns the user-facing string for a given provisioning state. Backend
/// owns state; iOS owns presentation.
public func displayText(for state: ProvisionState, replacementCount: Int) -> String {
    let prefix = replacementCount > 0 ? "Replacing — " : ""
    switch state {
    case .queued:         return "\(prefix)Waiting for capacity..."
    case .findingGpu:     return "\(prefix)Finding GPU..."
    case .creatingPod:    return "\(prefix)Creating pod..."
    case .fetchingImage:  return "\(prefix)Fetching container..."
    case .warmingModel:   return "\(prefix)Warming up AI model..."
    case .connecting:     return "\(prefix)Connecting..."
    case .ready:          return "Ready"
    case .failed:         return "Something went wrong"
    case .terminated:     return "Session ended"
    }
}

/// Returns a more specific user-facing message for a failure, refined by
/// category. Falls back to the generic "Something went wrong" if the category
/// is unknown or nil.
public func displayText(for failureCategory: FailureCategory?) -> String {
    guard let category = failureCategory else { return "Something went wrong" }
    switch category {
    case .spotCapacity, .podCreateFailed, .transientRunpod:
        return "GPU capacity is temporarily exhausted — try again shortly"
    case .podBootStall:
        return "Pod took too long to start — try again"
    case .warmModelTimeout:
        return "AI model took too long to start — try again"
    case .podVanished:
        return "Pod was reclaimed during setup — try again"
    case .monthlyCap:
        return "Monthly usage cap reached"
    case .unknown:
        return "Something went wrong"
    }
}
