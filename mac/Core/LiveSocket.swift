import Foundation

/// Keeps a WebSocket to /v1/live open. Each `{"version":N}` frame calls `onVersion`; every (re)connect calls
/// `onConnected` so the app pulls anything it missed while disconnected.
public final class LiveSocket: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public static func backoff(attempt: Int) -> TimeInterval { min(30, pow(2, Double(attempt))) }

    private let makeRequest: @Sendable () -> URLRequest?
    private let onVersion: @Sendable (Int) -> Void
    private let onConnected: @Sendable () -> Void
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var attempt = 0
    private var pingTimer: Timer?
    private var stopped = true
    private let queue = DispatchQueue(label: "live-socket")

    public init(makeRequest: @escaping @Sendable () -> URLRequest?, onVersion: @escaping @Sendable (Int) -> Void, onConnected: @escaping @Sendable () -> Void) {
        self.makeRequest = makeRequest
        self.onVersion = onVersion
        self.onConnected = onConnected
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    public func start() {
        queue.async {
            self.stopped = false
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    /// Reconnect now (after wake or a network change) instead of waiting out the backoff.
    public func reconnectNow() {
        queue.async {
            guard !self.stopped else { return }
            self.attempt = 0
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connect()
        }
    }

    private func connect() {
        guard !stopped, task == nil, let req = makeRequest() else { return }
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive(on: t)
        schedulePing(t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(s)):
                if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = obj["version"] as? Int {
                    self.onVersion(v)
                }
                self.receive(on: t)
            case .success:
                self.receive(on: t)
            case .failure:
                self.queue.async { self.retry(after: t) }
            }
        }
    }

    private func schedulePing(_ t: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.task === t, !self.stopped else { return }
            t.send(.string("ping")) { _ in }
            self.schedulePing(t)
        }
    }

    private func retry(after failed: URLSessionWebSocketTask) {
        guard task === failed, !stopped else { return }
        task = nil
        let delay = Self.backoff(attempt: attempt)
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { self.attempt = 0 }
        onConnected()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.retry(after: webSocketTask) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        queue.async { self.retry(after: ws) }
    }
}
