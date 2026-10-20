import XCTest

/// Phase D2 flows that run inside the app: consent, identify and reset, opt-out, server errors,
/// the offline queue with a kill and relaunch, cold and warm deep links, and session rotation.
/// Fresh install and upgrade need simctl and run in tools/ios_flows.py.
/// Every assertion reads what tools/mock_ingest.mjs received.
final class SampleAppFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        MockIngest.reset()
        app = XCUIApplication()
    }

    override func tearDown() {
        MockIngest.setOffline(false)
        app.terminate()
    }

    // MARK: Flows

    func testConsentChangeAppliesToTheNextEvent() {
        launch()
        setSwitch("Consent: analytics", on: true)
        tapButton("search")
        let first = waitForEvent("search")
        XCTAssertEqual(consent(of: first), ["analytics": true, "advertising": false])

        setSwitch("Consent: advertising", on: true)
        tapButton("login")
        let second = waitForEvent("login")
        XCTAssertEqual(consent(of: second), ["analytics": true, "advertising": true])
    }

    func testIdentifyThenResetStartsAnAnonymousUser() {
        launch()
        tapButton("identify sample_user_1")
        let identify = waitForEvent("identify")
        XCTAssertEqual(identify["userId"] as? String, "sample_user_1")
        let firstAnonymousId = identify["anonymousId"] as? String

        tapButton("sign_up")
        XCTAssertEqual(waitForEvent("sign_up")["userId"] as? String, "sample_user_1")

        tapButton("reset (logout)")
        tapButton("login")
        let afterReset = waitForEvent("login")
        XCTAssertNil(afterReset["userId"], "reset() must clear the user id")
        XCTAssertNotEqual(afterReset["anonymousId"] as? String, firstAnonymousId, "reset() must create a new anonymous id")
        XCTAssertNil(afterReset.context["traits"], "reset() must clear the traits")
    }

    func testOptOutDropsEventsAndIsRememberedAcrossLaunches() {
        launch()
        setSwitch("Collection enabled (off = opt-out)", on: false)
        MockIngest.reset()
        tapButton("view_item")
        tapButton("flush now")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(MockIngest.requests().isEmpty, "nothing may be sent while opted out")

        app.terminate()
        launch()
        XCTAssertEqual(switchValue("Collection enabled (off = opt-out)"), false, "opt-out must survive a relaunch")
        tapButton("view_item")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(MockIngest.requests().isEmpty, "nothing may be sent after relaunching opted out, not even app_opened")

        setSwitch("Collection enabled (off = opt-out)", on: true)
        tapButton("add_to_cart")
        waitForEvent("add_to_cart")
    }

    func testServerErrorsAreRetriedOrDropped() {
        launch()
        // 503: kept and sent again.
        MockIngest.failNext(status: 503)
        tapButton("view_item")
        let retried = waitForEvent("view_item", timeout: 90, pressFlush: true)
        XCTAssertTrue(
            failedAttempts(status: 503).contains {
                $0.eventName == "view_item" && $0["messageId"] as? String == retried["messageId"] as? String
            },
            "the delivered view_item must be the same event that got the 503")

        // 429 with Retry-After: kept and sent again after the wait.
        MockIngest.failNext(status: 429, retryAfter: 2)
        tapButton("add_to_wishlist")
        waitForEvent("add_to_wishlist", timeout: 90, pressFlush: true)
        XCTAssertTrue(failedAttempts(status: 429).contains { $0.eventName == "add_to_wishlist" })

        // 400: dropped, never sent again.
        MockIngest.failNext(status: 400)
        tapButton("remove_from_cart")
        let deadline = Date().addingTimeInterval(20)
        while failedAttempts(status: 400).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(failedAttempts(status: 400).contains { $0.eventName == "remove_from_cart" })
        for _ in 0..<3 {
            tapButton("flush now")
            Thread.sleep(forTimeInterval: 2)
        }
        tapButton("search")
        let events = MockIngest.waitForDelivered { $0.contains { $0.eventName == "search" } }
        XCTAssertFalse(events.contains { $0.eventName == "remove_from_cart" }, "a batch answered with 400 must be dropped")
    }

    func testOfflineQueueSurvivesAKillAndIsSentAfterReconnecting() {
        launch()
        MockIngest.setOffline(true)
        tapButton("send 200 queue_test_event")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(MockIngest.deliveredEvents().filter { $0.eventName == "queue_test_event" }.isEmpty)

        app.terminate()
        MockIngest.setOffline(false)
        launch()
        let events = MockIngest.waitForDelivered(
            timeout: 120,
            whileWaiting: { self.tapButton("flush now") },
            until: { Self.queueIndexes(in: $0).count >= 200 }
        )
        XCTAssertEqual(Self.queueIndexes(in: events), Set(1...200), "all 200 queued events must arrive after the relaunch")
        let duplicates = events.filter { $0.eventName == "queue_test_event" }.count - Self.queueIndexes(in: events).count
        XCTAssertEqual(duplicates, 0, "no queued event may be sent twice")
    }

    func testDeepLinkWhileRunningAddsClickIdsAndCampaign() {
        launch()
        app.open(URL(string: "sfereexample://match/7?utm_source=flow_test&utm_medium=sms&gclid=warm-gclid")!)
        let link = waitForEvent("deep_link_opened")
        XCTAssertEqual(link.properties["url"] as? String, "sfereexample://match/7?utm_source=flow_test&utm_medium=sms&gclid=warm-gclid")
        XCTAssertTrue(Set(link.properties.keys).isSubset(of: ["url", "referring_application", "sfere_dedup_id"]))

        tapButton("view_item")
        let next = waitForEvent("view_item")
        XCTAssertEqual((next.context["clientIds"] as? [String: Any])?["gclid"] as? String, "warm-gclid")
        XCTAssertEqual((next.context["campaign"] as? [String: Any])?["source"] as? String, "flow_test")
    }

    func testColdStartDeepLinkAddsClickIdsAndCampaign() {
        launch()
        app.terminate()
        MockIngest.reset()
        let url = "sfereexample://match/42?utm_source=cold_start&gclid=cold-gclid"
        app.open(URL(string: url)!)
        let link = waitForEvent("deep_link_opened")
        XCTAssertEqual(link.properties["url"] as? String, url)
        XCTAssertEqual((link.context["clientIds"] as? [String: Any])?["gclid"] as? String, "cold-gclid")
        XCTAssertEqual((link.context["campaign"] as? [String: Any])?["source"] as? String, "cold_start")
        XCTAssertTrue(MockIngest.deliveredEvents().contains { $0.eventName == "app_opened" }, "a cold start sends app_opened too")
    }

    func testSessionRotatesAfterTheTimeout() {
        launch(arguments: ["-sample.sessionTimeoutMinutes", "1"])
        tapButton("search")
        guard let firstSession = waitForEvent("search").sessionId else { return XCTFail("search has no context.session.id") }

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 65)
        app.activate()
        tapButton("login")
        let login = waitForEvent("login")
        let secondSession = login.sessionId
        XCTAssertNotNil(secondSession)
        XCTAssertNotEqual(secondSession, firstSession, "a new session must start after 1 minute in the background")
        let started = MockIngest.deliveredEvents().filter { $0.eventName == "session_started" }
        XCTAssertTrue(started.contains { $0.sessionId == secondSession }, "session_started must be sent for the new session")
    }

    // MARK: Helpers

    private func launch(arguments: [String] = []) {
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Sfere Sample"].waitForExistence(timeout: 15))
    }

    @discardableResult
    private func waitForEvent(
        _ name: String, timeout: TimeInterval = 20, pressFlush: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [String: Any] {
        let events = MockIngest.waitForDelivered(timeout: timeout, whileWaiting: pressFlush ? { self.tapButton("flush now") } : nil) {
            $0.contains { $0.eventName == name }
        }
        guard let event = events.last(where: { $0.eventName == name }) else {
            XCTFail("\(name) never reached the mock within \(Int(timeout)) s", file: file, line: line)
            return [:]
        }
        return event
    }

    private func failedAttempts(status: Int) -> [[String: Any]] {
        MockIngest.requests().filter { ($0["injectedStatus"] as? Int) == status }.flatMap(MockIngest.batch(of:))
    }

    private func consent(of event: [String: Any]) -> [String: Bool]? {
        (event.context["consent"] as? [String: Any])?["categoryPreferences"] as? [String: Bool]
    }

    private static func queueIndexes(in events: [[String: Any]]) -> Set<Int> {
        Set(events.filter { $0.eventName == "queue_test_event" }.compactMap { ($0.properties["index"] as? NSNumber)?.intValue })
    }

    /// Scrolls the form until the button is on screen, then taps it.
    private func tapButton(_ label: String) {
        let button = app.buttons[label].firstMatch
        reveal(button, label: label)
        button.tap()
    }

    private func switchValue(_ label: String) -> Bool {
        let toggle = app.switches[label].firstMatch
        reveal(toggle, label: label)
        return (toggle.value as? String) == "1"
    }

    private func setSwitch(_ label: String, on: Bool) {
        guard switchValue(label) != on else { return }
        // Tap the switch itself (right edge); tapping the label does not toggle a SwiftUI Toggle.
        app.switches[label].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let predicate = NSPredicate(format: "value == %@", on ? "1" : "0")
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app.switches[label].firstMatch)], timeout: 5), .completed,
            "\(label) did not switch \(on ? "on" : "off")")
    }

    private func reveal(_ element: XCUIElement, label: String) {
        let form = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for direction in [true, false] {
            for _ in 0..<25 where !(element.exists && element.isHittable) {
                if direction { form.swipeUp(velocity: .slow) } else { form.swipeDown(velocity: .slow) }
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(label) is not on screen")
    }
}
