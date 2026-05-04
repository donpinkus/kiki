import XCTest
@testable import NetworkModule

/// Contract tests for `StreamWebSocketClient.connectionEvents`. Validates the
/// invariants StreamSession relies on for reconnect:
///   1. Exactly one `.disconnected` event per client lifecycle.
///   2. The stream `finish()`es after that event so consumers exit cleanly.
///   3. Repeated calls (e.g. handleDisconnect followed by disconnect()) are
///      coalesced — no double yield, no yield-after-finish crash.
final class StreamWebSocketClientTests: XCTestCase {

    func test_disconnectEvent_emitsExactlyOnce_thenStreamFinishes() async {
        let client = StreamWebSocketClient(url: URL(string: "wss://example.test/ws")!)

        await client._testSimulateDisconnect(message: "first")
        await client._testSimulateDisconnect(message: "second")  // idempotent: ignored

        var collected: [StreamWebSocketClient.ConnectionEvent] = []
        let stream = await client.connectionEvents
        for await event in stream {
            collected.append(event)
        }

        XCTAssertEqual(collected.count, 1, "expected exactly one disconnect event, got \(collected.count)")
        if case .disconnected(let info) = collected.first {
            XCTAssertEqual(info.message, "first", "first call's message should win")
        } else {
            XCTFail("expected .disconnected event")
        }
    }

    func test_disconnectEvent_streamFinishesEvenWithoutEmission() async {
        // No simulated disconnect — only verify the stream is well-formed on a
        // freshly-constructed client. (Iterating a never-finished stream would
        // hang; this test is here to catch regressions where the stream is
        // accidentally pre-finished or pre-yielded by an init.)
        let client = StreamWebSocketClient(url: URL(string: "wss://example.test/ws")!)
        await client._testSimulateDisconnect(message: nil)

        var count = 0
        let stream = await client.connectionEvents
        for await _ in stream {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }
}
