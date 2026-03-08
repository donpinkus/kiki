import SwiftUI
import CanvasModule
import ResultModule

/// Central coordinator that owns all module view models and manages cross-module communication.
@Observable
final class AppCoordinator {

    // MARK: - Properties

    let canvasViewModel = CanvasViewModel()
    let resultViewModel = ResultViewModel()

    // MARK: - Lifecycle

    init() {}
}
