import Foundation
import Segment

extension RawEvent {
    /// Edits `context` as a dictionary. The base library keeps it as `JSON`.
    mutating func editContext(_ edit: (inout [String: Any]) -> Void) {
        var context = self.context?.dictionaryValue ?? [:]
        edit(&context)
        self.context = try? JSON(context)
    }
}

// MARK: - Lifecycle rename

/// Renames the base library's lifecycle and deep-link events to Sfere's snake_case names
/// (`fixtures/event-names.json`). Runs first among the enrichment plugins.
final class LifecycleRenamePlugin: Plugin {
    let type = PluginType.enrichment
    weak var analytics: Analytics?

    static let renames: [String: String] = [
        "Application Installed": "app_installed",
        "Application Opened": "app_opened",
        "Application Updated": "app_updated",
        "Application Backgrounded": "app_backgrounded",
        "Application Foregrounded": "app_foregrounded",
        "Deep Link Opened": "deep_link_opened",
    ]

    /// Property renames per (already renamed) event.
    static let propertyRenames: [String: [String: String]] = [
        "deep_link_opened": ["referrer": "referring_application", "sourceApplication": "referring_application"],
    ]

    /// Properties kept per (already renamed) event; any other key is dropped. The base library
    /// copies every open-URL option into `deep_link_opened`, and each would become a warehouse
    /// column. Click IDs and UTMs already travel in `context.clientIds` / `context.campaign`.
    static let keptProperties: [String: Set<String>] = [
        "deep_link_opened": ["url", "referring_application"],
    ]

    func execute<T: RawEvent>(event: T?) -> T? {
        guard var track = event as? TrackEvent, let newName = Self.renames[track.event] else { return event }
        track.event = newName
        if let renames = Self.propertyRenames[newName], var properties = track.properties?.dictionaryValue {
            for (old, new) in renames {
                if let value = properties.removeValue(forKey: old) {
                    properties[new] = value
                }
            }
            if let kept = Self.keptProperties[newName] {
                properties = properties.filter { kept.contains($0.key) }
            }
            track.properties = try? JSON(properties)
        }
        return track as? T
    }
}

// MARK: - Enrichment

/// Port of the browser SDK's enrichment plugin: library stamp, session, consent, carried traits,
/// session click IDs and campaign, and `properties.sfere_dedup_id` on track.
final class SfereEnrichmentPlugin: Plugin {
    let type = PluginType.enrichment
    weak var analytics: Analytics?
    private let state: SfereState

    init(state: SfereState) {
        self.state = state
    }

    func execute<T: RawEvent>(event: T?) -> T? {
        guard var working = event else { return event }

        let sessionId = state.touchSession()
        let clicks = state.clicks
        let consent = state.consent
        let traits = working.type == "identify" ? [:] : state.traits

        working.editContext { context in
            // Replaces the base library's own stamp; the base moves to `library.base`.
            context["library"] = [
                "name": SfereVersion.libraryName,
                "version": SfereVersion.current,
                "base": SfereVersion.baseLibrary,
            ]
            context["session"] = ["id": sessionId]

            if let consent {
                context["consent"] = ["categoryPreferences": consent]
            }

            if !traits.isEmpty {
                let existing = context["traits"] as? [String: Any] ?? [:]
                context["traits"] = traits.merging(existing) { _, eventValue in eventValue }
            }

            if !clicks.ids.isEmpty {
                let existing = context["clientIds"] as? [String: Any] ?? [:]
                context["clientIds"] = (clicks.ids as [String: Any]).merging(existing) { _, eventValue in eventValue }
            }

            if !clicks.campaign.isEmpty {
                let existing = context["campaign"] as? [String: Any] ?? [:]
                context["campaign"] = existing.merging(clicks.campaign) { _, stored in stored }
            }
        }

        if var track = working as? TrackEvent {
            var properties = track.properties?.dictionaryValue ?? [:]
            let current = properties["sfere_dedup_id"]
            if current == nil || current is NSNull {
                properties["sfere_dedup_id"] = track.messageId ?? ""
                track.properties = try? JSON(properties)
            }
            return track as? T
        }
        return working
    }
}

// MARK: - Sanitizer

/// Runs on the upload destination's own timeline, after everything else, and removes what must
/// never reach the wire (WIRE-CONTRACT §3, §4): `_metadata`, an empty `integrations`, base-library
/// extras that would become warehouse columns, and `clientIds` keys outside the fixed list.
final class SfereSanitizerPlugin: Plugin {
    let type = PluginType.enrichment
    weak var analytics: Analytics?

    /// Context keys the base library adds that the contract does not carry.
    static let droppedContextKeys = ["instanceId", "referrer", "__eventOrigin"]

    func execute<T: RawEvent>(event: T?) -> T? {
        guard var working = event else { return event }
        working._metadata = nil
        working.metrics = nil
        if let integrations = working.integrations?.dictionaryValue, integrations.isEmpty {
            working.integrations = nil
        }
        working.editContext { context in
            for key in Self.droppedContextKeys {
                context.removeValue(forKey: key)
            }
            // The base library sends the identifier for vendor as device.id. The Android SDK sends
            // no device id, so neither does iOS until the contract adds one.
            if var device = context["device"] as? [String: Any] {
                device.removeValue(forKey: "id")
                context["device"] = device
            }
            if let ids = context["clientIds"] as? [String: Any] {
                let allowed = ids.filter { DeepLinkParser.allowedClientIdKeys.contains($0.key) }
                context["clientIds"] = allowed.isEmpty ? nil : allowed
            }
        }
        return working
    }
}
