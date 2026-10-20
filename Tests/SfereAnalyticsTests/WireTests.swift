import Foundation
import Segment
import XCTest

@testable import SfereAnalytics

/// End to end through the real base library: events in, captured HTTP requests out.
final class WireTests: XCTestCase {
    private var writeKeys = [String]()
    private var directories = [URL]()

    override func tearDown() {
        // The base library keeps per-key state in a UserDefaults suite; leave no trace behind.
        for key in writeKeys {
            UserDefaults.standard.removePersistentDomain(forName: "com.segment.storage.\(key)")
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        writeKeys = []
        directories = []
    }

    override static func setUp() {
        super.setUp()
        removeTestPreferenceSuites()
    }

    override static func tearDown() {
        // cfprefsd can still write a suite back after this; the next run's setUp sweeps it.
        removeTestPreferenceSuites()
        super.tearDown()
    }

    private func makeSfere(host: String, uploader: CapturingUploader, clock: SfereClock = SystemClock()) -> (Sfere, String) {
        let writeKey = uniqueWriteKey()
        writeKeys.append(writeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sfere-tests-\(UUID().uuidString)")
        directories.append(directory)

        let config = SfereConfiguration(writeKey: writeKey, host: host)
        config.flushAt = 100
        // Lifecycle events come from UIApplication notifications; tests send the base names directly.
        config.trackLifecycleEvents = false
        config.store = InMemoryStore()
        config.uploader = uploader
        config.clock = clock
        config.storageMode = .diskAtURL(directory)
        let sfere = Sfere(configuration: config)
        sfere.analytics?.waitUntilStarted()
        return (sfere, writeKey)
    }

    /// Flushes until `count` events were uploaded (the base library writes events asynchronously).
    private func flush(_ sfere: Sfere, uploader: CapturingUploader, until count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while uploader.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let flushed = expectation(description: "flush")
            sfere.analytics?.flush { flushed.fulfill() }
            wait(for: [flushed], timeout: 5)
        }
        XCTAssertGreaterThanOrEqual(uploader.events.count, count, "uploaded events", file: file, line: line)
    }

    /// The cross-platform parity scenario. The Android TransportTest (sfere-android-sdk) runs the same calls; with
    /// SFERE_PARITY_DIR set, each platform writes its upload body there for a key-by-key comparison.
    func testParityScenarioAndDeepLinkProperties() throws {
        let uploader = CapturingUploader()
        let (sfere, _) = makeSfere(host: "https://ingest.example.com", uploader: uploader)

        sfere.setConsent(["analytics": true, "advertising": false])
        sfere.identify(userId: "user_123", traits: ["email": "fan@example.com"])
        // Extra options, as UIKit passes them, must not become deep_link_opened properties.
        sfere.openURL(
            URL(string: "sfereexample://match/42?utm_source=instagram&gclid=G1&fbclid=F1")!,
            options: ["sourceApplication": "com.example.source", "UIApplicationOpenURLOptionsOpenInPlaceKey": false])
        sfere.track(
            "add_to_cart",
            properties: [
                "currency": "SAR", "value": 89.99,
                "items": [["item_id": "sku_12345", "item_name": "Away Jersey", "price": 89.99, "quantity": 1]],
            ])
        sfere.purchase(
            SferePurchase(
                transactionId: "order_1", currency: "SAR", value: 89.99,
                items: [SfereItem(itemId: "sku_12345", price: 89.99, quantity: 1)], dedupId: "order_1"))
        sfere.screen("Match Center")

        // session_started, identify, deep_link_opened, add_to_cart, purchase, screen
        flush(sfere, uploader: uploader, until: 6)
        let deepLink = try XCTUnwrap(uploader.events.first { ($0["event"] as? String) == "deep_link_opened" })
        XCTAssertEqual(Set((deepLink["properties"] as? [String: Any] ?? [:]).keys), ["url", "referring_application", "sfere_dedup_id"])
        let device = (deepLink["context"] as? [String: Any])?["device"] as? [String: Any]
        XCTAssertNil(device?["id"], "no device id on the wire")

        if let directory = ProcessInfo.processInfo.environment["SFERE_PARITY_DIR"], var body = uploader.requests.first?.json {
            body["batch"] = uploader.events  // the events may arrive in more than one upload
            try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios.json"))
        }
    }

    func testWirePayloadMatchesTheContract() throws {
        XCTAssertFalse(Telemetry.shared.enable, "base-library telemetry stays off")

        let uploader = CapturingUploader()
        let clock = FakeClock()
        let (sfere, writeKey) = makeSfere(host: "https://ingest.example.com", uploader: uploader, clock: clock)
        XCTAssertTrue(sfere.isActive)

        sfere.identify(userId: "user_123", traits: ["email": "fan@example.com"])
        sfere.openURL(URL(string: "sfereexample://match/42?utm_source=instagram&gclid=G1&fbclid=F1")!)
        // What the base library's lifecycle plugin sends on launch.
        sfere.analytics?.track(name: "Application Opened", properties: ["from_background": false])
        sfere.track(
            "add_to_cart",
            properties: [
                "currency": "SAR", "value": 89.99,
                "items": [["item_id": "sku_12345", "item_name": "Away Jersey", "price": 89.99, "quantity": 1]],
            ])
        sfere.setConsent(["analytics": true, "advertising": false])
        sfere.purchase(
            SferePurchase(
                transactionId: "order_1", currency: "SAR", value: 89.99,
                items: [SfereItem(itemId: "sku_12345", price: 89.99, quantity: 1)], dedupId: "order_1"))
        sfere.screen("Match Center")

        // session_started, identify, deep_link_opened, app_opened, add_to_cart, purchase, screen
        flush(sfere, uploader: uploader, until: 7)

        // Requests: only the batch endpoint, Basic auth, key in the body.
        XCTAssertEqual(uploader.requests.count, 1, "one batch upload")
        for captured in uploader.requests {
            XCTAssertEqual(captured.request.url?.absoluteString, "https://ingest.example.com/v1/batch/b")
            XCTAssertEqual(captured.request.httpMethod, "POST")
            XCTAssertEqual(
                captured.request.value(forHTTPHeaderField: "Authorization"),
                "Basic " + Data("\(writeKey):".utf8).base64EncodedString())
            XCTAssertEqual(captured.json["writeKey"] as? String, writeKey)
            XCTAssertNotNil(captured.json["sentAt"])
            let raw = try XCTUnwrap(String(data: captured.body, encoding: .utf8))
            XCTAssertFalse(raw.contains("_metadata"), "no _metadata on the wire")
            XCTAssertFalse(raw.contains("\"integrations\""), "no empty integrations on the wire")
            XCTAssertFalse(raw.contains("instanceId"), "no context.instanceId")
            XCTAssertFalse(raw.contains("\"referrer\""), "no context.referrer")
            XCTAssertFalse(raw.contains("analytics-swift\","), "base library stamp replaced")
        }

        let events = uploader.events
        func named(_ name: String) -> [[String: Any]] {
            events.filter { ($0["event"] as? String) == name || ($0["type"] as? String) == name }
        }

        XCTAssertEqual(named("session_started").count, 1)
        XCTAssertEqual(named("app_opened").count, 1, "lifecycle name renamed")
        XCTAssertTrue(named("Application Opened").isEmpty)
        XCTAssertEqual(named("deep_link_opened").count, 1)
        XCTAssertEqual(
            (named("deep_link_opened").first?["properties"] as? [String: Any])?["url"] as? String,
            "sfereexample://match/42?utm_source=instagram&gclid=G1&fbclid=F1")

        // Every event: library stamp and one session.
        let sessionIds = Set(events.compactMap { (($0["context"] as? [String: Any])?["session"] as? [String: Any])?["id"] as? NSNumber })
        XCTAssertEqual(sessionIds, [NSNumber(value: clock.now)])
        for event in events {
            let context = try XCTUnwrap(event["context"] as? [String: Any])
            let library = try XCTUnwrap(context["library"] as? [String: Any])
            XCTAssertEqual(library["name"] as? String, "@fanfinity/sfere-ios")
            XCTAssertEqual(library["version"] as? String, SfereVersion.current)
            XCTAssertNotNil(event["messageId"])
            XCTAssertNotNil(event["anonymousId"])
        }

        // track: dedup id, click IDs, campaign, carried traits; consent only after it was set.
        let addToCart = try XCTUnwrap(named("add_to_cart").first)
        let addProperties = try XCTUnwrap(addToCart["properties"] as? [String: Any])
        XCTAssertEqual(addProperties["sfere_dedup_id"] as? String, addToCart["messageId"] as? String)
        let addContext = try XCTUnwrap(addToCart["context"] as? [String: Any])
        XCTAssertEqual(addContext["clientIds"] as? [String: String], ["gclid": "G1", "fbc": "fb.1.\(clock.now).F1"])
        XCTAssertEqual((addContext["campaign"] as? [String: Any])?["source"] as? String, "instagram")
        XCTAssertEqual((addContext["traits"] as? [String: Any])?["email"] as? String, "fan@example.com")
        XCTAssertNil(addContext["consent"])
        XCTAssertEqual(addToCart["userId"] as? String, "user_123")

        let purchase = try XCTUnwrap(named("purchase").first)
        XCTAssertEqual((purchase["properties"] as? [String: Any])?["sfere_dedup_id"] as? String, "order_1")
        let purchaseConsent =
            ((purchase["context"] as? [String: Any])?["consent"] as? [String: Any])?["categoryPreferences"] as? [String: Bool]
        XCTAssertEqual(purchaseConsent, ["analytics": true, "advertising": false])

        let identify = try XCTUnwrap(named("identify").first)
        XCTAssertEqual((identify["traits"] as? [String: Any])?["email"] as? String, "fan@example.com")
        XCTAssertNil((identify["context"] as? [String: Any])?["traits"], "identify carries traits at the top level")
        XCTAssertNil((named("screen").first?["properties"] as? [String: Any])?["sfere_dedup_id"])
    }

    func testDebugHttpHostIsCalledOverHttp() {
        let uploader = CapturingUploader()
        let (sfere, _) = makeSfere(host: "http://127.0.0.1:4311", uploader: uploader)
        sfere.track("view_item")
        flush(sfere, uploader: uploader, until: 2)
        XCTAssertEqual(Set(uploader.requests.compactMap(\.request.url?.absoluteString)), ["http://127.0.0.1:4311/v1/batch/b"])
    }

    func testResetStartsAFreshIdentityAndSession() {
        let uploader = CapturingUploader()
        let clock = FakeClock()
        let (sfere, _) = makeSfere(host: "https://ingest.example.com", uploader: uploader, clock: clock)
        sfere.identify(userId: "user_123", traits: ["email": "fan@example.com"])
        let firstAnonymousId = sfere.anonymousId
        clock.advance(minutes: 1)
        sfere.reset()
        sfere.track("view_item")
        flush(sfere, uploader: uploader, until: 4)

        let viewItem = uploader.events.first { ($0["event"] as? String) == "view_item" }
        XCTAssertNil(viewItem?["userId"])
        XCTAssertNotEqual(viewItem?["anonymousId"] as? String, firstAnonymousId)
        let context = viewItem?["context"] as? [String: Any]
        XCTAssertNil(context?["traits"])
        XCTAssertEqual(((context?["session"] as? [String: Any])?["id"] as? NSNumber)?.int64Value, clock.now)
        XCTAssertEqual(uploader.events.filter { ($0["event"] as? String) == "session_started" }.count, 2)
    }

    func testOptOutStopsCollection() {
        let uploader = CapturingUploader()
        let (sfere, _) = makeSfere(host: "https://ingest.example.com", uploader: uploader)
        sfere.setEnabled(false)
        XCTAssertFalse(sfere.isActive)
        sfere.track("view_item")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        sfere.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(uploader.requests.isEmpty)

        sfere.setEnabled(true)
        sfere.track("view_item")
        flush(sfere, uploader: uploader, until: 1)
        XCTAssertTrue(uploader.events.contains { ($0["event"] as? String) == "view_item" })
    }
}
