import Foundation
import Segment

/// Version and naming stamped on every event as `context.library` (WIRE-CONTRACT §4).
public enum SfereVersion {
    /// This SDK's version. Kept in step with the release tag.
    public static let current = "0.1.0-beta.2"
    static let libraryName = "@fanfinity/sfere-ios"
    static var baseLibrary: String { "analytics-swift@\(Analytics.version())" }
}

// MARK: - Logging

/// Logs only when `SfereConfiguration.debug` is on. Nothing here ever throws or traps.
final class SfereLogger {
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Sfere] \(message())")
    }

    /// Configuration mistakes are always printed: the SDK disables itself and the developer must see why.
    func error(_ message: String) {
        print("[Sfere] ERROR: \(message)")
    }
}

// MARK: - Clock

/// Milliseconds since the Unix epoch. Injected so session and click-ID tests are deterministic.
protocol SfereClock {
    func nowMs() -> Int64
}

struct SystemClock: SfereClock {
    func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

// MARK: - Key-value store

/// Where the SDK keeps its own state (session, consent, traits, click IDs, opt-out).
protocol SfereKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

final class UserDefaultsStore: SfereKeyValueStore {
    private let defaults: UserDefaults

    init(suiteName: String = "io.sfere.analytics") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class InMemoryStore: SfereKeyValueStore {
    private var values = [String: Data]()
    private let lock = NSLock()

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}

extension SfereKeyValueStore {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func encode<T: Encodable>(_ value: T?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

// MARK: - Host

/// A validated ingestion origin. Events go to `{origin}/v1/batch/b`.
struct SfereHost: Equatable {
    /// `https` in production; `http` only in debug builds, for a local mock.
    let scheme: String
    /// Host, plus `:port` when one was given.
    let authority: String

    var isInsecure: Bool { scheme == "http" }
    /// What the base library calls `apiHost`: no scheme. It appends `/b` and prefixes `https://`.
    var apiHost: String { "\(authority)/v1/batch" }
    var origin: String { "\(scheme)://\(authority)" }

    enum ValidationError: Error, CustomStringConvertible {
        case notAnOrigin(String)
        case insecure(String)

        var description: String {
            switch self {
            case .notAnOrigin(let host):
                return
                    "\"host\" must be an http(s) origin without a path, query or fragment, e.g. \"https://ingest.example.com\". Got \"\(host)\"."
            case .insecure(let host):
                return "\"host\" must use https in release builds. Got \"\(host)\"."
            }
        }
    }

    static func validate(_ raw: String, allowInsecure: Bool = isDebugBuild) -> Result<SfereHost, ValidationError> {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty,
            components.path.isEmpty || components.path == "/",
            components.query == nil, components.fragment == nil,
            components.user == nil, components.password == nil
        else {
            return .failure(.notAnOrigin(raw))
        }
        if scheme == "http" && !allowInsecure {
            return .failure(.insecure(raw))
        }
        let authority = components.port.map { "\(host):\($0)" } ?? host
        return .success(SfereHost(scheme: scheme, authority: authority.lowercased()))
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - JSON values

/// Converts caller-supplied values to what the base library can serialise, dropping anything else
/// rather than letting it reach the base library's fatal-on-error JSON conversion.
enum JSONValues {
    static func sanitize(_ dictionary: [String: Any]?, logger: SfereLogger? = nil) -> [String: Any]? {
        guard let dictionary else { return nil }
        return sanitizeObject(dictionary, path: "", logger: logger)
    }

    private static func sanitizeObject(_ object: [String: Any], path: String, logger: SfereLogger?) -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in object {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            if let clean = sanitizeValue(value, path: childPath, logger: logger) {
                result[key] = clean
            }
        }
        return result
    }

    private static func sanitizeValue(_ value: Any, path: String, logger: SfereLogger?) -> Any? {
        switch value {
        case is NSNull:
            return NSNull()
        case let number as NSNumber:
            if !number.doubleValue.isFinite {
                logger?.debug("Dropped \(path): non-finite number.")
                return nil
            }
            return number
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            guard double.isFinite else {
                logger?.debug("Dropped \(path): non-finite number.")
                return nil
            }
            return double
        case let decimal as Decimal:
            return decimal
        case let date as Date:
            return date
        case let url as URL:
            return url.absoluteString
        case let array as [Any]:
            return array.enumerated().compactMap { sanitizeValue($0.element, path: "\(path)[\($0.offset)]", logger: logger) }
        case let object as [String: Any]:
            return sanitizeObject(object, path: path, logger: logger)
        default:
            logger?.debug("Dropped \(path): unsupported type \(type(of: value)).")
            return nil
        }
    }

    static func json(_ dictionary: [String: Any]?, logger: SfereLogger? = nil) -> JSON? {
        guard let clean = sanitize(dictionary, logger: logger) else { return nil }
        return try? JSON(clean)
    }
}
