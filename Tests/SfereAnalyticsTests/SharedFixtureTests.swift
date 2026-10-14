import Foundation
import XCTest
@testable import SfereAnalytics

/// The tables every Sfere SDK must agree on (`fixtures/`).
final class SharedFixtureTests: XCTestCase {
    func testEveryDeepLinkCase() throws {
        let fixture = try Fixtures.json("deeplinks.json")
        let nowMs = try XCTUnwrap(fixture["nowMs"] as? NSNumber).int64Value
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let url = try XCTUnwrap(testCase["url"] as? String, name)
            let parsed = DeepLinkParser.parse(url, nowMs: nowMs)
            XCTAssertEqual(parsed.clientIds, testCase["clientIds"] as? [String: String], "clientIds: \(name)")
            XCTAssertEqual(parsed.campaign, testCase["campaign"] as? [String: String], "campaign: \(name)")
        }
    }

    func testParserTablesMatchFixture() throws {
        let fixture = try Fixtures.json("deeplinks.json")
        XCTAssertEqual(DeepLinkParser.urlClickIds, fixture["urlClickIds"] as? [String: String])
        XCTAssertEqual(DeepLinkParser.campaignParams, fixture["campaignParams"] as? [String: String])
        XCTAssertEqual(DeepLinkParser.allowedClientIdKeys, Set(fixture["allowedClientIdKeys"] as? [String] ?? []))
    }

    func testEventRenamesMatchFixture() throws {
        let fixture = try Fixtures.json("event-names.json")
        XCTAssertEqual(LifecycleRenamePlugin.renames, fixture["renames"] as? [String: String])
        XCTAssertEqual(LifecycleRenamePlugin.propertyRenames, fixture["propertyRenames"] as? [String: [String: String]])
    }
}
