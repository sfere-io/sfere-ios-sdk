import Foundation

/// One product line in `properties.items[]`, with the GA4 field names from EVENTS.md.
/// GA4 needs `itemId` or `itemName` on every item.
public struct SfereItem: Equatable {
    public var itemId: String?
    public var itemName: String?
    public var price: Double?
    public var quantity: Int?
    public var itemBrand: String?
    /// `item_category`, `item_category2` … `item_category5`, in order. Extra entries are ignored.
    public var itemCategories: [String]
    public var itemVariant: String?
    public var itemListId: String?
    public var itemListName: String?
    public var index: Int?
    public var coupon: String?
    public var discount: Double?
    public var affiliation: String?
    public var locationId: String?
    /// Extra keys (for example `image_url`), forwarded unchanged.
    public var extra: [String: Any]

    public init(
        itemId: String? = nil,
        itemName: String? = nil,
        price: Double? = nil,
        quantity: Int? = nil,
        itemBrand: String? = nil,
        itemCategories: [String] = [],
        itemVariant: String? = nil,
        itemListId: String? = nil,
        itemListName: String? = nil,
        index: Int? = nil,
        coupon: String? = nil,
        discount: Double? = nil,
        affiliation: String? = nil,
        locationId: String? = nil,
        extra: [String: Any] = [:]
    ) {
        self.itemId = itemId
        self.itemName = itemName
        self.price = price
        self.quantity = quantity
        self.itemBrand = itemBrand
        self.itemCategories = itemCategories
        self.itemVariant = itemVariant
        self.itemListId = itemListId
        self.itemListName = itemListName
        self.index = index
        self.coupon = coupon
        self.discount = discount
        self.affiliation = affiliation
        self.locationId = locationId
        self.extra = extra
    }

    public var properties: [String: Any] {
        var result = extra
        result["item_id"] = itemId
        result["item_name"] = itemName
        result["price"] = price
        result["quantity"] = quantity
        result["item_brand"] = itemBrand
        for (offset, category) in itemCategories.prefix(5).enumerated() {
            result[offset == 0 ? "item_category" : "item_category\(offset + 1)"] = category
        }
        result["item_variant"] = itemVariant
        result["item_list_id"] = itemListId
        result["item_list_name"] = itemListName
        result["index"] = index
        result["coupon"] = coupon
        result["discount"] = discount
        result["affiliation"] = affiliation
        result["location_id"] = locationId
        return result
    }

    public static func == (lhs: SfereItem, rhs: SfereItem) -> Bool {
        NSDictionary(dictionary: lhs.properties).isEqual(to: rhs.properties)
    }
}

/// The GA4 `purchase` event. Sent with `Sfere.shared.purchase(_:)`.
public struct SferePurchase {
    public var transactionId: String
    /// ISO 4217 code, e.g. "SAR".
    public var currency: String
    public var value: Double
    public var items: [SfereItem]
    public var tax: Double?
    public var shipping: Double?
    public var coupon: String?
    /// Set this to the same value your server uses when the server also sends this purchase, so
    /// destinations count it once (for example the order id). Defaults to the event's messageId.
    public var dedupId: String?

    public init(
        transactionId: String,
        currency: String,
        value: Double,
        items: [SfereItem],
        tax: Double? = nil,
        shipping: Double? = nil,
        coupon: String? = nil,
        dedupId: String? = nil
    ) {
        self.transactionId = transactionId
        self.currency = currency
        self.value = value
        self.items = items
        self.tax = tax
        self.shipping = shipping
        self.coupon = coupon
        self.dedupId = dedupId
    }

    public var properties: [String: Any] {
        var result: [String: Any] = [
            "transaction_id": transactionId,
            "currency": currency,
            "value": value,
            "items": items.map(\.properties),
        ]
        result["tax"] = tax
        result["shipping"] = shipping
        result["coupon"] = coupon
        result["sfere_dedup_id"] = dedupId
        return result
    }
}
