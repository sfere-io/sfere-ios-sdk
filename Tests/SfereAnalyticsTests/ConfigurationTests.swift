import Foundation
import Segment
import XCTest

@testable import SfereAnalytics

final class ConfigurationTests: XCTestCase {
    // MARK: Host

    func testValidHosts() throws {
        let plain = try SfereHost.validate("https://ingest.example.com", allowInsecure: false).get()
        XCTAssertEqual(plain.apiHost, "ingest.example.com/v1/batch")
        XCTAssertFalse(plain.isInsecure)

        let withSlashAndPort = try SfereHost.validate("https://Ingest.Example.com:8443/", allowInsecure: false).get()
        XCTAssertEqual(withSlashAndPort.apiHost, "ingest.example.com:8443/v1/batch")
    }

    func testRejectedHosts() {
        for bad in [
            "", "ingest.example.com", "ftp://ingest.example.com", "https://ingest.example.com/v1",
            "https://ingest.example.com?x=1", "https://ingest.example.com#f", "https://user@ingest.example.com",
        ] {
            if case .success = SfereHost.validate(bad, allowInsecure: true) {
                XCTFail("accepted \(bad)")
            }
        }
    }

    func testHttpOnlyWhenInsecureIsAllowed() {
        if case .success = SfereHost.validate("http://127.0.0.1:4311", allowInsecure: false) {
            XCTFail("release builds must reject http")
        }
        XCTAssertEqual(try SfereHost.validate("http://127.0.0.1:4311", allowInsecure: true).get().apiHost, "127.0.0.1:4311/v1/batch")
    }

    func testInvalidSetupLeavesAnInactiveInstance() {
        let config = SfereConfiguration(writeKey: uniqueWriteKey(), host: "https://ingest.example.com/path")
        config.store = InMemoryStore()
        let sfere = Sfere(configuration: config)
        XCTAssertFalse(sfere.isActive)
        // Calls are ignored, never crash.
        sfere.track("view_item")
        sfere.identify(userId: "u1")
        sfere.openURL(URL(string: "sfereexample://p?gclid=x")!)
        sfere.flush()
        sfere.reset()

        let emptyKey = Sfere(configuration: SfereConfiguration(writeKey: "  ", host: "https://ingest.example.com"))
        XCTAssertFalse(emptyKey.isActive)
    }

    // MARK: Requests and settings

    func testRequestsGetBasicAuthAndHttpOnlyForAnInsecureHost() throws {
        let original = URLRequest(url: URL(string: "https://127.0.0.1:4311/v1/batch/b")!)

        let secure = try SfereHost.validate("https://ingest.example.com", allowInsecure: false).get()
        let shaped = SfereRequests.shape(original, writeKey: "key:secret", host: secure)
        XCTAssertEqual(shaped.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("key:secret:".utf8).base64EncodedString())
        XCTAssertEqual(shaped.url?.scheme, "https")

        let insecure = try SfereHost.validate("http://127.0.0.1:4311", allowInsecure: true).get()
        XCTAssertEqual(
            SfereRequests.shape(original, writeKey: "key:secret", host: insecure).url?.absoluteString, "http://127.0.0.1:4311/v1/batch/b")
    }

    func testInlineSettingsCarryOurApiHostAndNoMetrics() throws {
        let settings = try XCTUnwrap(SfereSettings.settings(writeKey: "key:secret", apiHost: "ingest.example.com/v1/batch"))
        let segment = try XCTUnwrap(settings.integrationSettings(forKey: "Segment.io"))
        XCTAssertEqual(segment["apiKey"] as? String, "key:secret")
        XCTAssertEqual(segment["apiHost"] as? String, "ingest.example.com/v1/batch")
        XCTAssertEqual((settings.metrics?.dictionaryValue?["sampleRate"] as? NSNumber)?.doubleValue, 0)
    }

    func testSettingsRequestIsAnsweredLocally() throws {
        let uploader = CapturingUploader()
        let settingsData = SfereSettings.data(writeKey: "key:secret", apiHost: "ingest.example.com/v1/batch")
        let session = SfereHTTPSession(settingsData: settingsData, uploader: uploader)
        let request = URLRequest(url: URL(string: "https://ingest.example.com/v1/batch/projects/key:secret/settings")!)

        let answered = expectation(description: "settings answered")
        let task = session.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, settingsData)
            answered.fulfill()
        }
        XCTAssertEqual(task.state, .suspended)
        task.resume()
        wait(for: [answered], timeout: 2)
        XCTAssertTrue(uploader.requests.isEmpty, "the settings fetch must not reach the network")
    }

    /// The base library resumes the settings task and drops its reference at once. Under XCTest it
    /// skips the settings request entirely, so only this test covers what a real app does: if the
    /// answer never arrives, event processing stays paused and the app sends nothing.
    func testSettingsAnswerArrivesWhenNobodyKeepsTheTask() {
        let settingsData = SfereSettings.data(writeKey: "key:secret", apiHost: "ingest.example.com/v1/batch")
        let session = SfereHTTPSession(settingsData: settingsData, uploader: CapturingUploader())
        let request = URLRequest(url: URL(string: "https://ingest.example.com/v1/batch/projects/key:secret/settings")!)

        let answered = expectation(description: "settings answered")
        session.dataTask(with: request) { data, _, _ in
            XCTAssertEqual(data, settingsData)
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 2)
    }

    // MARK: E-commerce

    func testPurchaseSerialisesToGA4Keys() throws {
        let purchase = SferePurchase(
            transactionId: "order_98765",
            currency: "SAR",
            value: 256.96,
            items: [
                SfereItem(
                    itemId: "sku_12345", itemName: "Away Jersey", price: 89.99, quantity: 2,
                    itemBrand: "Al-Hilal", itemCategories: ["Apparel", "Jerseys"], itemVariant: "XL",
                    itemListId: "related", itemListName: "Related products", index: 3, coupon: "SUMMER20",
                    discount: 10, affiliation: "Riyadh store", locationId: "ChIJ1", extra: ["image_url": "https://x/y.png"])
            ],
            tax: 16.99,
            shipping: 10,
            coupon: "SUMMER20",
            dedupId: "order_98765"
        )
        let properties = purchase.properties
        XCTAssertEqual(
            Set(properties.keys), ["transaction_id", "currency", "value", "items", "tax", "shipping", "coupon", "sfere_dedup_id"])
        let item = try XCTUnwrap((properties["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(item.keys),
            [
                "item_id", "item_name", "price", "quantity", "item_brand", "item_category", "item_category2",
                "item_variant", "item_list_id", "item_list_name", "index", "coupon", "discount", "affiliation",
                "location_id", "image_url",
            ])
        XCTAssertEqual(item["item_category2"] as? String, "Jerseys")
    }

    func testPurchaseOmitsUnsetOptionalFields() {
        let properties = SferePurchase(transactionId: "o1", currency: "SAR", value: 1, items: [SfereItem(itemId: "s1")]).properties
        XCTAssertEqual(Set(properties.keys), ["transaction_id", "currency", "value", "items"])
        XCTAssertEqual((properties["items"] as? [[String: Any]])?.first?.keys.sorted(), ["item_id"])
    }

    func testUnsupportedValuesAreDroppedNotFatal() {
        let clean = JSONValues.sanitize([
            "ok": 1, "nan": Double.nan, "object": NSObject(), "nested": ["date": Date(timeIntervalSince1970: 0)],
        ])
        XCTAssertNotNil(clean?["ok"])
        XCTAssertNil(clean?["nan"])
        XCTAssertNil(clean?["object"])
        XCTAssertNotNil(JSONValues.json(clean))
    }
}
