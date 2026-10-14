import Foundation
import Segment
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Inline settings

/// Settings are built in code and never fetched (WIRE-CONTRACT §5): the ingestion endpoint has no
/// settings route, and the base library's remote metrics must stay off.
enum SfereSettings {
    static func json(writeKey: String, apiHost: String) -> [String: Any] {
        [
            "integrations": [
                "Segment.io": [
                    "apiKey": writeKey,
                    // Must be ours: the upload destination adopts whatever apiHost settings carry.
                    "apiHost": apiHost,
                ],
            ],
            "plan": [
                "track": ["__default": ["enabled": true]],
                "identify": ["__default": ["enabled": true]],
                "group": ["__default": ["enabled": true]],
            ],
            "metrics": ["sampleRate": 0],
        ]
    }

    static func data(writeKey: String, apiHost: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: json(writeKey: writeKey, apiHost: apiHost), options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func settings(writeKey: String, apiHost: String) -> Settings? {
        try? JSONDecoder().decode(Settings.self, from: data(writeKey: writeKey, apiHost: apiHost))
    }
}

// MARK: - Upload transport

/// Sends one upload request. The default uses URLSession; tests capture requests instead.
protocol SfereUploader: AnyObject {
    func upload(_ request: URLRequest, body: Data, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> SfereSessionTask
    func invalidate()
}

final class URLSessionUploader: SfereUploader {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func upload(_ request: URLRequest, body: Data, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> SfereSessionTask {
        let task = session.uploadTask(with: request, from: body, completionHandler: completion)
        return SfereSessionTask(underlying: task)
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }
}

/// A task the base library can resume. Wraps a real URLSession task, or a local answer.
final class SfereSessionTask: UploadTask {
    private let underlying: URLSessionTask?
    private let localWork: (() -> Void)?
    private var localState: URLSessionTask.State = .suspended
    private let lock = NSLock()

    init(underlying: URLSessionTask) {
        self.underlying = underlying
        self.localWork = nil
    }

    init(localWork: @escaping () -> Void) {
        self.underlying = nil
        self.localWork = localWork
    }

    var state: URLSessionTask.State {
        if let underlying { return underlying.state }
        lock.lock(); defer { lock.unlock() }
        return localState
    }

    func resume() {
        if let underlying {
            underlying.resume()
            return
        }
        lock.lock()
        guard localState == .suspended else { lock.unlock(); return }
        localState = .running
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.localWork?()
            self?.lock.lock()
            self?.localState = .completed
            self?.lock.unlock()
        }
    }
}

// MARK: - HTTP session

/// The base library's HTTP session, with two changes:
/// - any data task (the base library only uses them for its settings fetch) is answered locally
///   with the inline settings, so nothing is ever requested from a settings host;
/// - uploads pass through to the uploader unchanged.
final class SfereHTTPSession: HTTPSession {
    typealias DataTaskType = SfereSessionTask
    typealias UploadTaskType = SfereSessionTask

    private let settingsData: Data
    private let uploader: SfereUploader

    init(settingsData: Data, uploader: SfereUploader) {
        self.settingsData = settingsData
        self.uploader = uploader
    }

    func dataTask(with request: URLRequest, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> SfereSessionTask {
        let data = settingsData
        return SfereSessionTask {
            let response = request.url.flatMap {
                HTTPURLResponse(url: $0, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
            }
            completionHandler(data, response, nil)
        }
    }

    func uploadTask(with request: URLRequest, fromFile file: URL, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> SfereSessionTask {
        guard let body = try? Data(contentsOf: file) else {
            return SfereSessionTask { completionHandler(nil, nil, URLError(.cannotOpenFile)) }
        }
        return uploader.upload(request, body: body, completion: completionHandler)
    }

    func uploadTask(with request: URLRequest, from bodyData: Data?, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> SfereSessionTask {
        uploader.upload(request, body: bodyData ?? Data(), completion: completionHandler)
    }

    func finishTasksAndInvalidate() {
        // The uploader is shared by every HTTPSession the base library creates; it lives as long
        // as the SDK instance, so it is not invalidated here.
    }
}

// MARK: - Request shaping

enum SfereRequests {
    static func basicAuthorization(writeKey: String) -> String {
        "Basic " + Data("\(writeKey):".utf8).base64EncodedString()
    }

    /// Adds Basic auth (the base library sends the key only in the body) and, for a debug-only
    /// http host, rewrites the scheme the base library hard-codes as https.
    static func shape(_ request: URLRequest, writeKey: String, host: SfereHost) -> URLRequest {
        var shaped = request
        shaped.setValue(basicAuthorization(writeKey: writeKey), forHTTPHeaderField: "Authorization")
        if host.isInsecure, let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "http"
            shaped.url = components.url
        }
        return shaped
    }
}
