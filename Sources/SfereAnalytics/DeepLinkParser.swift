import Foundation

/// Reads ad click IDs and campaign parameters from a deep link, universal link, or a bare query
/// string (for example an install referrer). Same rules as `packages/shared` in the browser SDK
/// repo; `fixtures/deeplinks.json` is the shared test table.
enum DeepLinkParser {
    /// URL parameter -> `context.clientIds` key. `fbclid` is handled separately: it becomes `fbc`.
    static let urlClickIds: [String: String] = [
        "gclid": "gclid",
        "wbraid": "wbraid",
        "gbraid": "gbraid",
        "ttclid": "ttclid",
        "ScCid": "scclid",
        "twclid": "twclid",
        "epik": "epik",
        "msclkid": "msclkid",
        "li_fat_id": "li_fat_id",
        "oppref": "oppref",
        "rdt_cid": "rdt_cid",
    ]

    /// URL parameter -> `context.campaign` key.
    static let campaignParams: [String: String] = [
        "utm_source": "source",
        "utm_medium": "medium",
        "utm_campaign": "name",
        "utm_term": "term",
        "utm_content": "content",
        "gad_source": "gad_source",
        "gad_campaignid": "gad_campaignid",
    ]

    /// The only keys `context.clientIds` may carry; the destinations fix these names.
    static let allowedClientIdKeys: Set<String> = [
        "fbp", "fbc", "ttp", "ttclid", "scid", "scclid", "epik", "li_fat_id", "msclkid",
        "oppref", "obref", "gclid", "wbraid", "gbraid", "twclid", "rdt_cid", "clarity_uid", "clarity_sid",
    ]

    struct Result: Equatable {
        var clientIds: [String: String] = [:]
        var campaign: [String: String] = [:]
        /// The raw `fbclid`, kept so a repeat of the same click does not refresh `fbc`'s timestamp.
        var fbclid: String?

        var isEmpty: Bool { clientIds.isEmpty && campaign.isEmpty }
    }

    /// Meta's documented click-ID format: `fb.<subdomainIndex>.<creationTimeMs>.<fbclid>`.
    static func fbc(fromFbclid fbclid: String, nowMs: Int64) -> String {
        "fb.1.\(nowMs).\(fbclid)"
    }

    static func parse(_ url: URL, nowMs: Int64) -> Result {
        parse(url.absoluteString, nowMs: nowMs)
    }

    /// `link` is either a URL with a scheme, or a bare query string such as `utm_source=x&gclid=y`.
    static func parse(_ link: String, nowMs: Int64) -> Result {
        let queryItems: [URLQueryItem]
        if let components = URLComponents(string: link), components.scheme != nil {
            queryItems = components.queryItems ?? []
        } else {
            var components = URLComponents()
            components.percentEncodedQuery = link.hasPrefix("?") ? String(link.dropFirst()) : link
            queryItems = components.queryItems ?? []
        }

        var result = Result()
        for item in queryItems {
            guard let value = item.value, !value.isEmpty else { continue }
            if let key = urlClickIds[item.name] {
                result.clientIds[key] = value
            } else if let key = campaignParams[item.name] {
                result.campaign[key] = value
            } else if item.name == "fbclid" {
                result.fbclid = value
                result.clientIds["fbc"] = fbc(fromFbclid: value, nowMs: nowMs)
            }
        }
        return result
    }
}
