import Foundation
import XCTest

@testable import SfereAnalytics

final class FakeClock: SfereClock {
    var now: Int64

    init(_ now: Int64 = 1_760_349_600_000) {
        self.now = now
    }

    func nowMs() -> Int64 { now }

    func advance(minutes: Int) { now += Int64(minutes) * 60_000 }
}

/// Records every upload instead of sending it, and answers 200.
final class CapturingUploader: SfereUploader {
    struct Captured {
        let request: URLRequest
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        var events: [[String: Any]] { json["batch"] as? [[String: Any]] ?? [] }
    }

    private let lock = NSLock()
    private var captured = [Captured]()

    var requests: [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    var events: [[String: Any]] { requests.flatMap(\.events) }

    func upload(_ request: URLRequest, body: Data, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void)
        -> SfereSessionTask
    {
        lock.lock()
        captured.append(Captured(request: request, body: body))
        lock.unlock()
        return SfereSessionTask {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            completion(Data(#"{"ok":true}"#.utf8), response, nil)
        }
    }

    func invalidate() {}
}

enum Fixtures {
    /// `fixtures/` at the repository root, found from this file's location.
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SfereAnalyticsTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("fixtures")

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// A unique write key per test: the base library refuses two instances with the same key.
/// Prefix of every test write key. The base library names a UserDefaults suite after the key, so
/// the prefix lets the tests find and delete those suites without touching any real app's.
let testWriteKeyPrefix = "sferetest"

func uniqueWriteKey() -> String {
    "\(testWriteKeyPrefix)\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)):secret"
}

/// Deletes the base library's UserDefaults suites for test write keys, including any left by an
/// earlier run. cfprefsd can write a suite's plist back after it is deleted, so the suite is
/// emptied and synchronised first.
func removeTestPreferenceSuites() {
    let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    let suitePrefix = "com.segment.storage.\(testWriteKeyPrefix)"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
    for file in files where file.hasPrefix(suitePrefix) && file.hasSuffix(".plist") {
        let domain = String(file.dropLast(".plist".count))
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent(file))
    }
}
