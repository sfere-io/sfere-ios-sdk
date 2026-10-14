import Foundation
import Segment

/// Settings for `Sfere.setup(_:)`.
public final class SfereConfiguration {
    /// The Sfere browser key (`keyId:secret`). It is public by design and only allows ingest.
    /// Never put a server key in an app.
    public let writeKey: String
    /// The ingestion origin: `https://` + host, with no path, e.g. `https://ingest.example.com`.
    /// `http://` is accepted only in debug builds, for a local mock.
    public let host: String

    /// Events per upload. Default 20.
    public var flushAt: Int = 20
    /// Seconds between uploads. Default 30. The SDK also uploads when the app goes to the background.
    public var flushInterval: TimeInterval = 30
    /// Inactivity, in minutes, after which a new session starts. Bringing the app to the
    /// foreground counts as activity. Default 30.
    public var sessionTimeoutMinutes: Int = 30
    /// Send `app_installed`, `app_opened`, `app_updated` and `app_backgrounded`. Default true.
    public var trackLifecycleEvents: Bool = true
    /// Send `deep_link_opened` from `openURL(_:)`. Click IDs and campaign values are read from
    /// links either way. Default true.
    public var trackDeepLinks: Bool = true
    /// Initial consent categories, e.g. `["analytics": true, "advertising": false]`. Sent as
    /// `context.consent.categoryPreferences`; left out until set. A later `setConsent` wins.
    public var consent: [String: Bool]?
    /// Print payloads and warnings to the console. Default false.
    public var debug: Bool = false

    // Test seams. Internal so they never become public API.
    var clock: SfereClock = SystemClock()
    var store: SfereKeyValueStore?
    var uploader: SfereUploader?
    var storageMode: StorageMode = .disk
    var allowInsecureHost: Bool = SfereHost.isDebugBuild

    public init(writeKey: String, host: String) {
        self.writeKey = writeKey
        self.host = host
    }
}
