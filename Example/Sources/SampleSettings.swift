import Foundation

/// Host, key and session timeout for the sample app. `Sfere.setup` runs once per launch, so a
/// change takes effect on the next launch.
struct SampleSettings {
    /// The Mac's tools/mock_ingest.mjs. The Simulator shares the Mac's network.
    static let defaultHost = "http://127.0.0.1:4320"
    static let defaultWriteKey = "sample-key:local"
    static let defaultSessionTimeoutMinutes = 30

    private let defaults = UserDefaults.standard
    private static let hostKey = "sample.host"
    private static let writeKeyKey = "sample.writeKey"
    private static let sessionTimeoutKey = "sample.sessionTimeoutMinutes"

    var host: String {
        get { defaults.string(forKey: Self.hostKey) ?? Self.defaultHost }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Self.hostKey) }
    }

    var writeKey: String {
        get { defaults.string(forKey: Self.writeKeyKey) ?? Self.defaultWriteKey }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Self.writeKeyKey) }
    }

    var sessionTimeoutMinutes: Int {
        // integer(forKey:) also reads the string a launch argument (-sample.sessionTimeoutMinutes 1) sets.
        get { defaults.object(forKey: Self.sessionTimeoutKey) == nil ? Self.defaultSessionTimeoutMinutes : defaults.integer(forKey: Self.sessionTimeoutKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.sessionTimeoutKey) }
    }
}
