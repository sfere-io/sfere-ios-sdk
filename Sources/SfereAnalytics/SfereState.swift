import Foundation
import Segment

/// The SDK's own persisted state: session, consent, carried traits, session click IDs, opt-out.
/// All methods are thread-safe. Callbacks are never invoked while the lock is held, so a callback
/// may call back into the SDK (for example to track `session_started`).
final class SfereState {
    struct Session: Codable, Equatable {
        var id: Int64
        var last: Int64
    }

    struct Clicks: Codable, Equatable {
        var ids: [String: String] = [:]
        var campaign: [String: String] = [:]
        var fbclid: String?
    }

    private enum Keys {
        static let session = "session"
        static let consent = "consent"
        static let traits = "traits"
        static let clicks = "clicks"
        static let enabled = "enabled"
    }

    private let store: SfereKeyValueStore
    private let clock: SfereClock
    private let keyPrefix: String
    private let idleMs: Int64
    private let lock = NSLock()

    /// Called once per new session, after the state is saved and the lock released.
    var onSessionStarted: ((Int64) -> Void)?

    init(store: SfereKeyValueStore, clock: SfereClock, keyPrefix: String, sessionTimeoutMinutes: Int) {
        self.store = store
        self.clock = clock
        self.keyPrefix = keyPrefix
        self.idleMs = Int64(max(1, sessionTimeoutMinutes)) * 60_000
    }

    private func key(_ name: String) -> String { "\(keyPrefix).\(name)" }

    // MARK: Session

    /// Marks activity now and returns the current session id. Starts a new session when there is
    /// none or the last activity is older than the timeout; a new session also drops the previous
    /// session's click IDs.
    @discardableResult
    func touchSession() -> Int64 {
        let now = clock.nowMs()
        lock.lock()
        var session = store.decode(Session.self, forKey: key(Keys.session))
        var isNew = false
        if session == nil || now - session!.last > idleMs {
            session = Session(id: now, last: now)
            isNew = true
            store.set(nil, forKey: key(Keys.clicks))
        } else {
            session!.last = now
        }
        store.encode(session, forKey: key(Keys.session))
        lock.unlock()

        if isNew {
            onSessionStarted?(session!.id)
        }
        return session!.id
    }

    // MARK: Consent

    var consent: [String: Bool]? {
        get { store.decode([String: Bool].self, forKey: key(Keys.consent)) }
        set { store.encode(newValue, forKey: key(Keys.consent)) }
    }

    // MARK: Traits

    /// Identify traits, merged across identify calls, carried as `context.traits` on later events.
    var traits: [String: Any] {
        store.decode(JSON.self, forKey: key(Keys.traits))?.dictionaryValue ?? [:]
    }

    func mergeTraits(_ new: [String: Any]) {
        guard !new.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var merged = store.decode(JSON.self, forKey: key(Keys.traits))?.dictionaryValue ?? [:]
        merged.merge(new) { _, newer in newer }
        store.encode(try? JSON(merged), forKey: key(Keys.traits))
    }

    // MARK: Click IDs

    var clicks: Clicks {
        store.decode(Clicks.self, forKey: key(Keys.clicks)) ?? Clicks()
    }

    /// Records a link's click IDs and campaign values for the rest of the current session. A newer
    /// value replaces an older one; the same `fbclid` again keeps its original `fbc` timestamp.
    func recordLink(_ parsed: DeepLinkParser.Result) {
        guard !parsed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var clicks = store.decode(Clicks.self, forKey: key(Keys.clicks)) ?? Clicks()
        for (key, value) in parsed.clientIds where key != "fbc" {
            clicks.ids[key] = value
        }
        if let fbclid = parsed.fbclid, fbclid != clicks.fbclid, let fbc = parsed.clientIds["fbc"] {
            clicks.fbclid = fbclid
            clicks.ids["fbc"] = fbc
        }
        clicks.campaign.merge(parsed.campaign) { _, newer in newer }
        store.encode(clicks, forKey: key(Keys.clicks))
    }

    // MARK: Opt-out

    var enabled: Bool {
        get { store.decode(Bool.self, forKey: key(Keys.enabled)) ?? true }
        set { store.encode(newValue, forKey: key(Keys.enabled)) }
    }

    // MARK: Reset

    /// Logout: forget traits, the session and its click IDs. Consent and opt-out are device
    /// choices, not user identity, so they stay.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        store.set(nil, forKey: key(Keys.traits))
        store.set(nil, forKey: key(Keys.session))
        store.set(nil, forKey: key(Keys.clicks))
    }
}
