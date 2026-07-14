import Foundation

/// Best-effort mirror of product analytics + drawing assets to the Kiki Insights
/// microsite (the internal per-user analytics dashboard).
///
/// Design rules:
/// - **Off the canvas hot path.** Everything is fire-and-forget on a detached
///   actor; nothing here ever blocks drawing or the UI (CLAUDE.md #1).
/// - **No-op until configured** with a base URL, so pre-deploy builds and the
///   sign-in screen are unaffected. `configure` is called once from
///   `AppCoordinator.init`.
/// - **Auth reuses the existing access token** (CLAUDE.md #3: no new secret on
///   the client). Insights verifies it with the shared JWT secret and derives
///   `user_id` from the token's `sub`, so we never send a user id.
/// - **Bounded queue** with batched flush; failures re-queue (server errors) or
///   are dropped (client errors), never thrown.
actor InsightsSink {
    static let shared = InsightsSink()

    private var baseURL: URL?
    private var tokenProvider: (() async -> String?)?

    private var queue: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?

    private let batchSize = 25
    private let maxQueue = 500
    private let flushDelay: Duration = .seconds(3)

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Wire up the sink. `tokenProvider` returns the current access token (or nil
    /// if not signed in / refresh failed) — events stay queued until one exists.
    func configure(baseURL: URL?, tokenProvider: @escaping () async -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// Mirror a product event. `properties` must be JSON-serializable. `drawing_id`
    /// / `stream_id` are lifted to top-level columns Insights indexes on.
    func record(name: String, properties: [String: Any]?) {
        // Always enqueue (bounded) — even before `configure` runs or while the
        // service URL is unset — so the launch foreground event isn't lost to an
        // init-time race. `flush` is what gates on the URL. If never configured,
        // the queue just stays capped at `maxQueue` and never sends.
        var ev: [String: Any] = [
            "name": name,
            "occurred_at": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let properties, !properties.isEmpty {
            ev["properties"] = properties
            if let drawingId = properties["drawing_id"] as? String { ev["drawing_id"] = drawingId }
            if let streamId = properties["stream_id"] as? String { ev["stream_id"] = streamId }
        }
        queue.append(ev)
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }

        if queue.count >= batchSize {
            Task { await self.flush() }
        } else if flushTask == nil {
            flushTask = Task { [flushDelay] in
                try? await Task.sleep(for: flushDelay)
                await self.flush()
            }
        }
    }

    private func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard let baseURL, !queue.isEmpty else { return }
        guard let token = await tokenProvider?() else { return } // wait for auth
        let batch = queue
        queue.removeAll()

        guard let body = try? JSONSerialization.data(withJSONObject: ["events": batch]) else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("ingest"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 500 { requeue(batch) }
            // 4xx (bad token pre-refresh, etc.) → drop; don't spin.
        } catch {
            requeue(batch)
        }
    }

    private func requeue(_ batch: [[String: Any]]) {
        queue.insert(contentsOf: batch, at: 0)
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
    }

    /// Upload a drawing's thumbnail + generated image (multipart). Called once per
    /// drawing close. `drawing_id` is the SwiftData UUID (string) — Insights
    /// upserts on it, so repeated closes just refresh the assets.
    func uploadDrawing(
        id: String,
        prompt: String?,
        styleId: String?,
        updatedAt: Date,
        thumbnail: Data?,
        generated: Data?
    ) {
        guard baseURL != nil, thumbnail != nil || generated != nil else { return }
        let iso = isoFormatter.string(from: updatedAt)
        Task { await self.performDrawingUpload(id: id, prompt: prompt, styleId: styleId, updatedAtISO: iso, thumbnail: thumbnail, generated: generated) }
    }

    private func performDrawingUpload(
        id: String,
        prompt: String?,
        styleId: String?,
        updatedAtISO: String,
        thumbnail: Data?,
        generated: Data?
    ) async {
        guard let baseURL else { return }
        guard let token = await tokenProvider?() else { return }

        let boundary = "kiki-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        func appendFile(_ name: String, _ data: Data) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\n")
            body.append("Content-Type: image/jpeg\r\n\r\n")
            body.append(data)
            body.append("\r\n")
        }

        // drawing_id MUST precede the file parts — Insights' streaming multipart
        // parser needs the id set before it writes blobs.
        appendField("drawing_id", id)
        if let prompt { appendField("prompt", prompt) }
        if let styleId { appendField("style_id", styleId) }
        appendField("updated_at", updatedAtISO)
        if let thumbnail { appendFile("thumbnail", thumbnail) }
        if let generated { appendFile("generated", generated) }
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: baseURL.appendingPathComponent("ingest/drawing"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Upload a brush-dev stroke fixture: the BrushFixture JSON (replayable in
    /// BrushHarness) + an optional PNG snapshot of the canvas. Brush Studio's
    /// "Record strokes → Upload". Unlike the fire-and-forget event/drawing mirrors,
    /// this RETURNS success — it's an explicit user action (doubles as a brush
    /// bug-report), so a failed upload must not silently look uploaded.
    func uploadFixture(name: String?, note: String?, strokeCount: Int,
                       fixtureJSON: Data, snapshotPNG: Data?) async -> Bool {
        guard let baseURL else { return false }
        guard let token = await tokenProvider?() else { return false }

        let boundary = "kiki-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        func appendFilePart(_ name: String, filename: String, contentType: String, _ data: Data) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(contentType)\r\n\r\n")
            body.append(data)
            body.append("\r\n")
        }

        if let name, !name.isEmpty { appendField("name", name) }
        if let note, !note.isEmpty { appendField("note", note) }
        appendField("stroke_count", String(strokeCount))
        appendFilePart("fixture", filename: "fixture.json", contentType: "application/json", fixtureJSON)
        if let snapshotPNG {
            appendFilePart("snapshot", filename: "snapshot.png", contentType: "image/png", snapshotPNG)
        }
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: baseURL.appendingPathComponent("ingest/fixture"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
