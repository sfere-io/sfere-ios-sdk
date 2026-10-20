import Foundation
import SfereAnalytics

/// The events the sample app's buttons send, with GA4 properties as in EVENTS.md.
/// The Android sample app (sfere-android-sdk, sample/) sends the same list.
enum SampleEvents {
    private static let jersey = SfereItem(
        itemId: "SKU-JERSEY-HOME", itemName: "Home jersey", price: 299, quantity: 1, itemCategories: ["apparel"])
    private static let scarf = SfereItem(
        itemId: "SKU-SCARF", itemName: "Club scarf", price: 79, quantity: 2, itemCategories: ["accessories"])

    private static func itemsPayload(_ items: SfereItem...) -> [String: Any] {
        let value = items.reduce(0.0) { $0 + ($1.price ?? 0) * Double($1.quantity ?? 1) }
        return ["currency": "SAR", "value": value, "items": items.map(\.properties)]
    }

    private static func merging(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        base.merging(extra) { _, new in new }
    }

    /// Name and properties for every `track` button, in screen order.
    static let trackEvents: [(name: String, properties: [String: Any])] = [
        (
            "view_item_list",
            ["item_list_id": "new_season", "item_list_name": "New season", "items": [jersey.properties, scarf.properties]]
        ),
        ("select_item", ["item_list_id": "new_season", "items": [jersey.properties]]),
        ("view_item", itemsPayload(jersey)),
        ("add_to_wishlist", itemsPayload(scarf)),
        ("add_to_cart", itemsPayload(jersey)),
        ("remove_from_cart", itemsPayload(jersey)),
        ("view_cart", itemsPayload(jersey, scarf)),
        ("begin_checkout", itemsPayload(jersey, scarf)),
        ("add_shipping_info", merging(itemsPayload(jersey, scarf), ["shipping_tier": "standard"])),
        ("add_payment_info", merging(itemsPayload(jersey, scarf), ["payment_type": "card"])),
        ("refund", merging(itemsPayload(jersey), ["transaction_id": "T-SAMPLE-1"])),
        ("search", ["search_term": "home jersey"]),
        ("sign_up", ["method": "email"]),
        ("login", ["method": "email"]),
        ("generate_lead", ["currency": "SAR", "value": 50.0]),
        ("match_ticket_scanned", ["match_id": "42", "gate": "B"]),
    ]

    static func purchase() -> SferePurchase {
        SferePurchase(
            transactionId: "T-SAMPLE-\(Int(Date().timeIntervalSince1970 * 1000))",
            currency: "SAR",
            value: 457,
            items: [jersey, scarf],
            shipping: 20
        )
    }

    /// Events sent by the "send 200" button, for the offline-queue flow.
    static let queueTestCount = 200

    static let testDeepLink = URL(string: "sfereexample://match/42?utm_source=sample_app&utm_campaign=sdk_check&gclid=sample-gclid")!
}
