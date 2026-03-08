import Testing
@testable import SchedulerModule

@Suite("SchedulerState Tests")
struct SchedulerStateTests {
    @Test func idleState() {
        let state: SchedulerState = .idle
        if case .idle = state {
            #expect(true)
        } else {
            #expect(Bool(false))
        }
    }
}
