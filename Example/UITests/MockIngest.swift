import Foundation
import XCTest

/// Reads and controls tools/mock_ingest.mjs from the UI test runner. The Simulator shares the Mac's
/// network, so the mock is at 127.0.0.1. Override with TEST_RUNNER_SFERE_MOCK_URL.
enum MockIngest {
    static let baseURL = URL(string: ProcessInfo.processInfo.environment["SFERE_MOCK_URL"] ?? "http://127.0.0.1:4320")!

    static func reset() { post("/__reset") }
    static func setOffline(_ offline: Bool) { post("/__offline", ["offline": offline]) }
    static func failNext(status: Int, count: Int = 1, retryAfter: Int? = nil) {
        var body: [String: Any] = ["status": status, "count": count]
        if let retryAfter { body["retryAfter"] = retryAfter }
        post("/__fail", body)
    }

    /// Every request the mock recorded, oldest first.
    static func requests() -> [[String: Any]] {
        let data = send(URLRequest(url: baseURL.appendingPathComponent("__events")))
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// Events from batches the mock accepted (no injected failure), oldest first.
    static func deliveredEvents() -> [[String: Any]] {
        requests().filter { $0["injectedStatus"] == nil }.flatMap(batch(of:))
    }

    static func batch(of request: [String: Any]) -> [[String: Any]] {
        ((request["body"] as? [String: Any])?["batch"] as? [[String: Any]]) ?? []
    }

    /// Polls the delivered events until `condition` holds or the timeout passes. `whileWaiting` runs
    /// between polls, e.g. to press "flush now".
    @discardableResult
    static func waitForDelivered(
        timeout: TimeInterval = 20,
        whileWaiting: (() -> Void)? = nil,
        until condition: ([[String: Any]]) -> Bool
    ) -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        var events = deliveredEvents()
        while !condition(events) && Date() < deadline {
            whileWaiting?()
            Thread.sleep(forTimeInterval: 1)
            events = deliveredEvents()
        }
        return events
    }

    private static func post(_ path: String, _ body: [String: Any] = [:]) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = send(request)
    }

    private static func send(_ request: URLRequest) -> Data {
        var result = Data()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { XCTFail("Mock ingest unreachable at \(baseURL): \(error). Run tools/mock_ingest_ctl.sh start.") }
            result = data ?? Data()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return result
    }
}

extension Dictionary where Key == String, Value == Any {
    /// The event name of a track (`event`) or screen (`name`) call, or the type for other calls.
    var eventName: String { (self["event"] as? String) ?? (self["name"] as? String) ?? (self["type"] as? String ?? "") }
    var context: [String: Any] { self["context"] as? [String: Any] ?? [:] }
    var properties: [String: Any] { self["properties"] as? [String: Any] ?? [:] }
    var sessionId: Int64? { ((context["session"] as? [String: Any])?["id"] as? NSNumber)?.int64Value }
}
