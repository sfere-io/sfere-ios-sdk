import Foundation
import Segment
import XCTest
@testable import SfereAnalytics

final class PluginTests: XCTestCase {
    private var clock: FakeClock!
    private var state: SfereState!
    private var enrichment: SfereEnrichmentPlugin!

    override func setUp() {
        clock = FakeClock()
        state = SfereState(store: InMemoryStore(), clock: clock, keyPrefix: "sfere.test", sessionTimeoutMinutes: 30)
        enrichment = SfereEnrichmentPlugin(state: state)
    }

    private func trackEvent(_ name: String, properties: [String: Any]? = nil) -> TrackEvent {
        var event = TrackEvent(event: name, properties: properties.flatMap { try? JSON($0) })
        event.messageId = "msg-1"
        return event
    }

    // MARK: Rename

    func testLifecycleEventsAreRenamed() {
        let rename = LifecycleRenamePlugin()
        for (old, new) in LifecycleRenamePlugin.renames {
            XCTAssertEqual(rename.execute(event: trackEvent(old))?.event, new)
        }
        XCTAssertEqual(rename.execute(event: trackEvent("add_to_cart"))?.event, "add_to_cart")
    }

    func testDeepLinkPropertiesAreRenamed() {
        let renamed = LifecycleRenamePlugin().execute(event: trackEvent("Deep Link Opened", properties: [
            "url": "sfereexample://p", "sourceApplication": "com.apple.mobilesafari",
        ]))
        let properties = renamed?.properties?.dictionaryValue
        XCTAssertEqual(properties?["referring_application"] as? String, "com.apple.mobilesafari")
        XCTAssertNil(properties?["sourceApplication"])
        XCTAssertEqual(properties?["url"] as? String, "sfereexample://p")
    }

    // MARK: Enrichment

    func testEnrichmentStampsLibraryAndSession() throws {
        let event = try XCTUnwrap(enrichment.execute(event: trackEvent("view_item")))
        let context = try XCTUnwrap(event.context?.dictionaryValue)
        let library = try XCTUnwrap(context["library"] as? [String: Any])
        XCTAssertEqual(library["name"] as? String, "@fanfinity/sfere-ios")
        XCTAssertEqual(library["version"] as? String, SfereVersion.current)
        XCTAssertTrue((library["base"] as? String)?.hasPrefix("analytics-swift@") == true)
        let session = try XCTUnwrap(context["session"] as? [String: Any])
        XCTAssertEqual((session["id"] as? NSNumber)?.int64Value, clock.now)
        XCTAssertNil(context["consent"], "consent is omitted until set")
    }

    func testDedupIdDefaultsToMessageIdOnTrackOnly() throws {
        let tracked = try XCTUnwrap(enrichment.execute(event: trackEvent("purchase")))
        XCTAssertEqual(tracked.properties?.dictionaryValue?["sfere_dedup_id"] as? String, "msg-1")

        var screen = ScreenEvent(title: "Home", category: nil)
        screen.messageId = "msg-2"
        let screened = try XCTUnwrap(enrichment.execute(event: screen))
        XCTAssertNil(screened.properties?.dictionaryValue?["sfere_dedup_id"])
    }

    func testCallerDedupIdIsKept() throws {
        let tracked = try XCTUnwrap(enrichment.execute(event: trackEvent("purchase", properties: ["sfere_dedup_id": "order_1"])))
        XCTAssertEqual(tracked.properties?.dictionaryValue?["sfere_dedup_id"] as? String, "order_1")
    }

    func testConsentTraitsAndClicksAreAdded() throws {
        state.consent = ["analytics": true, "advertising": false]
        state.mergeTraits(["email": "fan@example.com"])
        state.touchSession()
        state.recordLink(DeepLinkParser.parse("sfereexample://p?gclid=G1&utm_source=ig", nowMs: clock.now))

        let event = try XCTUnwrap(enrichment.execute(event: trackEvent("add_to_cart")))
        let context = try XCTUnwrap(event.context?.dictionaryValue)
        let consent = (context["consent"] as? [String: Any])?["categoryPreferences"] as? [String: Bool]
        XCTAssertEqual(consent, ["analytics": true, "advertising": false])
        XCTAssertEqual((context["traits"] as? [String: Any])?["email"] as? String, "fan@example.com")
        XCTAssertEqual(context["clientIds"] as? [String: String], ["gclid": "G1"])
        XCTAssertEqual(context["campaign"] as? [String: String], ["source": "ig"])
    }

    func testIdentifyDoesNotCarryStoredTraitsInContext() throws {
        state.mergeTraits(["email": "fan@example.com"])
        var identify = IdentifyEvent(userId: "u1", traits: try JSON(["email": "fan@example.com"]))
        identify.messageId = "msg-3"
        let enriched = try XCTUnwrap(enrichment.execute(event: identify))
        XCTAssertNil(enriched.context?.dictionaryValue?["traits"])
    }

    // MARK: Sanitizer

    func testSanitizerRemovesWhatMustNotReachTheWire() throws {
        var event = trackEvent("view_item")
        event.integrations = try JSON([String: Any]())
        event._metadata = try JSONDecoder().decode(DestinationMetadata.self, from: Data(#"{"bundled":[],"unbundled":["X"],"bundledIds":[]}"#.utf8))
        event.context = try JSON([
            "instanceId": "abc",
            "referrer": ["url": "sfereexample://p"],
            "clientIds": ["gclid": "G1", "not_a_click_id": "x"],
            "app": ["name": "Club App"],
        ])

        let clean = try XCTUnwrap(SfereSanitizerPlugin().execute(event: event))
        XCTAssertNil(clean._metadata)
        XCTAssertNil(clean.integrations)
        let context = try XCTUnwrap(clean.context?.dictionaryValue)
        XCTAssertNil(context["instanceId"])
        XCTAssertNil(context["referrer"])
        XCTAssertEqual(context["clientIds"] as? [String: String], ["gclid": "G1"])
        XCTAssertNotNil(context["app"])

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(clean), encoding: .utf8))
        XCTAssertFalse(encoded.contains("_metadata"))
        XCTAssertFalse(encoded.contains("integrations"))
    }

    func testSanitizerKeepsIntegrationsTheCallerSet() throws {
        var event = trackEvent("view_item")
        event.integrations = try JSON(["Some Destination": false])
        let clean = try XCTUnwrap(SfereSanitizerPlugin().execute(event: event))
        XCTAssertEqual(clean.integrations?.dictionaryValue?["Some Destination"] as? Bool, false)
    }
}
