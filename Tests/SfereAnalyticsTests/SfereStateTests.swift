import Foundation
import XCTest

@testable import SfereAnalytics

final class SfereStateTests: XCTestCase {
    private var clock: FakeClock!
    private var store: InMemoryStore!
    private var state: SfereState!
    private var startedSessions: [Int64] = []

    override func setUp() {
        clock = FakeClock()
        store = InMemoryStore()
        startedSessions = []
        state = makeState()
    }

    private func makeState() -> SfereState {
        let state = SfereState(store: store, clock: clock, keyPrefix: "sfere.test", sessionTimeoutMinutes: 30)
        state.onSessionStarted = { [unowned self] id in self.startedSessions.append(id) }
        return state
    }

    func testFirstTouchStartsASessionWithTheCurrentTime() {
        XCTAssertEqual(state.touchSession(), clock.now)
        XCTAssertEqual(startedSessions, [clock.now])
    }

    func testActivityWithinTheTimeoutKeepsTheSession() {
        let first = state.touchSession()
        clock.advance(minutes: 29)
        XCTAssertEqual(state.touchSession(), first)
        clock.advance(minutes: 29)
        // Each touch moves the idle window, so 58 minutes of steady activity is still one session.
        XCTAssertEqual(state.touchSession(), first)
        XCTAssertEqual(startedSessions.count, 1)
    }

    func testInactivityLongerThanTheTimeoutRotatesTheSession() {
        let first = state.touchSession()
        clock.advance(minutes: 31)
        let second = state.touchSession()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second, clock.now)
        XCTAssertEqual(startedSessions, [first, second])
    }

    func testSessionSurvivesARestart() {
        let first = state.touchSession()
        clock.advance(minutes: 5)
        let restarted = makeState()
        XCTAssertEqual(restarted.touchSession(), first)
        XCTAssertEqual(startedSessions.count, 1)
    }

    func testCallbackMayCallBackIntoTheState() {
        // session_started is tracked from the callback, and that event touches the session again.
        state.onSessionStarted = { [unowned self] _ in _ = self.state.touchSession() }
        let expectation = expectation(description: "no deadlock")
        DispatchQueue.global().async {
            self.state.touchSession()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testClickIdsLastForTheSessionAndClearWhenItRotates() {
        state.touchSession()
        state.recordLink(DeepLinkParser.parse("sfereexample://p?gclid=G1&utm_source=ig", nowMs: clock.now))
        XCTAssertEqual(state.clicks.ids, ["gclid": "G1"])
        XCTAssertEqual(state.clicks.campaign, ["source": "ig"])

        clock.advance(minutes: 31)
        state.touchSession()
        XCTAssertEqual(state.clicks, SfereState.Clicks())
    }

    func testNewerClickReplacesOlderAndCampaignMergesPerKey() {
        state.touchSession()
        state.recordLink(DeepLinkParser.parse("sfereexample://p?gclid=G1&ttclid=T1&utm_source=ig&utm_medium=paid", nowMs: clock.now))
        state.recordLink(DeepLinkParser.parse("sfereexample://p?gclid=G2&utm_source=tiktok", nowMs: clock.now))
        XCTAssertEqual(state.clicks.ids, ["gclid": "G2", "ttclid": "T1"])
        XCTAssertEqual(state.clicks.campaign, ["source": "tiktok", "medium": "paid"])
    }

    func testSameFbclidKeepsItsFirstTimestamp() {
        state.touchSession()
        state.recordLink(DeepLinkParser.parse("sfereexample://p?fbclid=F1", nowMs: clock.now))
        let firstFbc = state.clicks.ids["fbc"]
        XCTAssertEqual(firstFbc, "fb.1.\(clock.now).F1")

        clock.advance(minutes: 1)
        state.recordLink(DeepLinkParser.parse("sfereexample://p?fbclid=F1", nowMs: clock.now))
        XCTAssertEqual(state.clicks.ids["fbc"], firstFbc)

        state.recordLink(DeepLinkParser.parse("sfereexample://p?fbclid=F2", nowMs: clock.now))
        XCTAssertEqual(state.clicks.ids["fbc"], "fb.1.\(clock.now).F2")
    }

    func testConsentIsUnsetUntilSetAndPersists() {
        XCTAssertNil(state.consent)
        state.consent = ["analytics": true, "advertising": false]
        XCTAssertEqual(makeState().consent, ["analytics": true, "advertising": false])
    }

    func testTraitsMergeAcrossIdentifyCalls() {
        state.mergeTraits(["email": "fan@example.com", "first_name": "Sara"])
        state.mergeTraits(["first_name": "Noura", "phone": "+966500000000"])
        let traits = makeState().traits
        XCTAssertEqual(traits["email"] as? String, "fan@example.com")
        XCTAssertEqual(traits["first_name"] as? String, "Noura")
        XCTAssertEqual(traits["phone"] as? String, "+966500000000")
    }

    func testResetClearsIdentityButKeepsConsentAndOptOut() {
        state.touchSession()
        state.mergeTraits(["email": "fan@example.com"])
        state.recordLink(DeepLinkParser.parse("sfereexample://p?gclid=G1", nowMs: clock.now))
        state.consent = ["analytics": true]
        state.enabled = false

        state.reset()

        XCTAssertTrue(state.traits.isEmpty)
        XCTAssertEqual(state.clicks, SfereState.Clicks())
        XCTAssertEqual(state.consent, ["analytics": true])
        XCTAssertFalse(state.enabled)
        // The next event starts a new session.
        clock.advance(minutes: 1)
        XCTAssertEqual(state.touchSession(), clock.now)
        XCTAssertEqual(startedSessions.count, 2)
    }

    func testOptOutDefaultsToEnabledAndPersists() {
        XCTAssertTrue(state.enabled)
        state.enabled = false
        XCTAssertFalse(makeState().enabled)
    }
}
