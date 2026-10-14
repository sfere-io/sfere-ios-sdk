import Foundation
import Segment
#if canImport(UIKit)
import UIKit
#endif

/// The Sfere SDK. Call `Sfere.setup(_:)` once at launch, then use `Sfere.shared`.
///
/// Every public method is safe to call at any time: before setup, after a failed setup, or while
/// opted out, calls do nothing. Nothing here throws or traps; mistakes are logged in debug mode.
public final class Sfere {
    // MARK: Shared instance

    private static let sharedLock = NSLock()
    private static var sharedInstance: Sfere?
    private static let inactive = Sfere(inactiveWith: SfereLogger(enabled: false))

    /// The instance created by `setup(_:)`. Before setup it is an inactive instance that ignores calls.
    public static var shared: Sfere {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return sharedInstance ?? inactive
    }

    /// Creates the shared instance. Call once, early in `application(_:didFinishLaunchingWithOptions:)`.
    /// A second call is ignored and returns the existing instance.
    @discardableResult
    public static func setup(_ configuration: SfereConfiguration) -> Sfere {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let existing = sharedInstance {
            existing.logger.error("setup(_:) was called more than once; the first configuration stays in use.")
            return existing
        }
        let instance = Sfere(configuration: configuration)
        sharedInstance = instance
        return instance
    }

    // MARK: Instance

    /// The underlying event pipeline. Nil when setup failed (invalid key or host).
    let analytics: Analytics?
    let state: SfereState?
    private let configuration: SfereConfiguration?
    private let logger: SfereLogger
    private var foregroundObserver: NSObjectProtocol?

    /// True when setup succeeded and events are being collected.
    public var isActive: Bool { analytics != nil && (state?.enabled ?? false) }

    /// The anonymous id of this install, or nil when inactive.
    public var anonymousId: String? { analytics?.anonymousId }

    private init(inactiveWith logger: SfereLogger) {
        analytics = nil
        state = nil
        configuration = nil
        self.logger = logger
    }

    init(configuration: SfereConfiguration) {
        let logger = SfereLogger(enabled: configuration.debug)
        self.logger = logger
        self.configuration = configuration

        let writeKey = configuration.writeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !writeKey.isEmpty else {
            logger.error("\"writeKey\" is empty. The SDK is inactive.")
            analytics = nil
            state = nil
            return
        }
        let host: SfereHost
        switch SfereHost.validate(configuration.host, allowInsecure: configuration.allowInsecureHost) {
        case .success(let valid):
            host = valid
        case .failure(let error):
            logger.error("\(error) The SDK is inactive.")
            analytics = nil
            state = nil
            return
        }

        // The base library reports usage metrics to its vendor unless told not to. This must be
        // off before the first instance exists (WIRE-CONTRACT §5: no third-party hosts).
        Telemetry.shared.enable = false

        let keyId = writeKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? writeKey
        let state = SfereState(
            store: configuration.store ?? UserDefaultsStore(),
            clock: configuration.clock,
            keyPrefix: "sfere.\(keyId)",
            sessionTimeoutMinutes: configuration.sessionTimeoutMinutes
        )
        self.state = state

        let settingsData = SfereSettings.data(writeKey: writeKey, apiHost: host.apiHost)
        let uploader = configuration.uploader ?? URLSessionUploader()
        let lifecycle: TrackedLifecycleEvent = configuration.trackLifecycleEvents
            ? [.applicationInstalled, .applicationUpdated, .applicationOpened, .applicationBackgrounded]
            : .none

        let segmentConfiguration = Configuration(writeKey: writeKey)
            .apiHost(host.apiHost)
            // Never contacted: the HTTP session answers the settings request locally.
            .cdnHost(host.apiHost)
            .defaultSettings(SfereSettings.settings(writeKey: writeKey, apiHost: host.apiHost))
            .flushAt(max(1, configuration.flushAt))
            .flushInterval(max(1, configuration.flushInterval))
            .httpConfig(HttpConfig(
                rateLimitConfig: RateLimitConfig(enabled: true),
                backoffConfig: BackoffConfig(enabled: true)
            ))
            .httpSession(SfereHTTPSession(settingsData: settingsData, uploader: uploader))
            .requestFactory { SfereRequests.shape($0, writeKey: writeKey, host: host) }
            .storageMode(configuration.storageMode)
            .errorHandler { error in logger.debug("Pipeline error: \(error)") }
        segmentConfiguration.setTrackedApplicationLifecycleEvents(lifecycle)

        let analytics = Analytics(configuration: segmentConfiguration)
        self.analytics = analytics

        analytics.add(plugin: LifecycleRenamePlugin())
        analytics.add(plugin: SfereEnrichmentPlugin(state: state))
        Self.installSanitizer(on: analytics)

        state.onSessionStarted = { [weak analytics] _ in
            analytics?.track(name: "session_started")
        }
        if state.consent == nil, let consent = configuration.consent {
            state.consent = consent
        }
        analytics.enabled = state.enabled

        #if canImport(UIKit) && !os(watchOS)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak state] _ in
            // Foregrounding counts as activity; a session that timed out in the background rotates here.
            state?.touchSession()
        }
        #endif

        logger.debug("Ready. Sending to \(host.origin)/v1/batch/b")
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Removes the base library's `_metadata` plugin from the upload destination and adds the
    /// Sfere sanitizer to that destination's own timeline, where it runs after every other change.
    static func installSanitizer(on analytics: Analytics) {
        guard let destination = analytics.find(pluginType: SegmentDestination.self) else { return }
        var metadataPlugins = [Plugin]()
        destination.apply { plugin in
            if plugin is DestinationMetadataPlugin {
                metadataPlugins.append(plugin)
            }
        }
        metadataPlugins.forEach { destination.remove(plugin: $0) }
        destination.add(plugin: SfereSanitizerPlugin())
    }

    // MARK: Events

    /// Records who the user is. `traits` (e.g. `email`, `phone`, `first_name`) are sent as plain
    /// values and carried on later events; the SDK never hashes them.
    public func identify(userId: String? = nil, traits: [String: Any]? = nil) {
        guard let analytics, let state else { return }
        let clean = JSONValues.sanitize(traits, logger: logger) ?? [:]
        state.mergeTraits(clean)
        let json = try? JSON(clean)
        if let userId, !userId.isEmpty {
            analytics.identify(userId: userId, traits: json)
        } else if let json {
            analytics.identify(traits: json)
        }
    }

    /// Sends a `track` event. Use the GA4 names from EVENTS.md where one exists (snake_case).
    public func track(_ name: String, properties: [String: Any]? = nil) {
        guard let analytics, validateEventName(name) else { return }
        validateProperties(properties, event: name)
        analytics.track(name: name, properties: JSONValues.json(properties, logger: logger))
    }

    /// Sends a `screen` event.
    public func screen(_ name: String, properties: [String: Any]? = nil) {
        guard let analytics else { return }
        analytics.screen(title: name, category: nil, properties: JSONValues.json(properties, logger: logger))
    }

    /// Sends a `group` event.
    public func group(_ groupId: String, traits: [String: Any]? = nil) {
        guard let analytics else { return }
        analytics.group(groupId: groupId, traits: JSONValues.json(traits, logger: logger))
    }

    /// Sends an `alias` event linking the current user to `newId`.
    public func alias(_ newId: String) {
        guard let analytics else { return }
        analytics.alias(newId: newId)
    }

    /// Sends the GA4 `purchase` event.
    public func purchase(_ purchase: SferePurchase) {
        track("purchase", properties: purchase.properties)
    }

    // MARK: Links

    /// Call from `application(_:open:options:)`, `scene(_:openURLContexts:)` and, for universal
    /// links, with `userActivity.webpageURL`. Click IDs (`gclid`, `fbclid`, …) and UTM values in the
    /// link are attached to every event for the rest of the session.
    public func openURL(_ url: URL, options: [String: Any] = [:]) {
        guard let analytics, let state, let configuration else { return }
        // Rotate first, so the link's click IDs belong to the session it starts.
        state.touchSession()
        state.recordLink(DeepLinkParser.parse(url, nowMs: configuration.clock.nowMs()))
        if configuration.trackDeepLinks {
            analytics.openURL(url, options: JSONValues.sanitize(options, logger: logger) ?? [:])
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// UIKit convenience for `application(_:open:options:)`.
    public func openURL(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
        var simple = [String: Any]()
        if let source = options[.sourceApplication] as? String {
            simple["referring_application"] = source
        }
        openURL(url, options: simple)
    }
    #endif

    // MARK: Consent, identity, delivery

    /// Replaces the consent categories sent as `context.consent.categoryPreferences` from the next
    /// event on, e.g. `["analytics": true, "advertising": false]`. Saved across launches.
    public func setConsent(_ consent: [String: Bool]) {
        state?.consent = consent
    }

    /// Logout: clears the user id, traits, the session and its click IDs, and creates a new
    /// anonymous id. Consent and opt-out stay.
    public func reset() {
        guard let analytics, let state else { return }
        analytics.reset()
        state.reset()
    }

    /// Uploads queued events now.
    public func flush() {
        analytics?.flush()
    }

    /// Opt in or out. Opting out stops collection, deletes events not yet uploaded, and is saved
    /// across launches.
    public func setEnabled(_ enabled: Bool) {
        guard let analytics, let state else { return }
        state.enabled = enabled
        analytics.enabled = enabled
        if !enabled {
            analytics.purgeStorage()
        }
    }

    // MARK: Validation (debug warnings only)

    private func validateEventName(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            logger.error("track(_:) needs an event name. The event was dropped.")
            return false
        }
        if name.count > 128 {
            logger.debug("Event name \"\(name.prefix(40))…\" is longer than 128 characters.")
        }
        if name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) == nil {
            logger.debug("Event name \"\(name)\" is not snake_case. Use the GA4 names from EVENTS.md where one exists.")
        }
        return true
    }

    private func validateProperties(_ properties: [String: Any]?, event: String) {
        guard logger.enabled, let properties else { return }
        if let value = properties["value"] {
            if !(value is NSNumber) || value is Bool {
                logger.debug("\(event): \"value\" should be a number.")
            }
            if properties["currency"] == nil {
                logger.debug("\(event): \"currency\" (ISO 4217) is required whenever \"value\" is set.")
            }
        }
        if let items = properties["items"] as? [[String: Any]] {
            for (index, item) in items.enumerated() where item["item_id"] == nil && item["item_name"] == nil {
                logger.debug("\(event): items[\(index)] needs \"item_id\" or \"item_name\".")
            }
        }
        for (key, value) in properties {
            if let array = value as? [Any], array.count > 100 {
                logger.debug("\(event): \"\(key)\" has \(array.count) values; keep arrays at 100 or fewer.")
            }
            if let string = value as? String, string.count > 512 {
                logger.debug("\(event): \"\(key)\" is longer than 512 characters.")
            }
        }
    }
}
