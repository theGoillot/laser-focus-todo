import Foundation

/// Talks to the backend's /v1 API with the Mac token in the Authorization header.
public struct APIClient: SyncAPI {
    public let baseURL: URL
    let token: String
    let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    public func postOps(_ ops: [Op], since: Int) async throws -> SyncResponse {
        var r = request("v1/ops", method: "POST", body: try JSONEncoder().encode(["ops": ops]))
        r.url = r.url.flatMap { URL(string: $0.absoluteString + "?since=\(since)") }
        return try await send(r)
    }

    public func sync(since: Int) async throws -> SyncResponse {
        var r = request("v1/sync")
        r.url = r.url.flatMap { URL(string: $0.absoluteString + "?since=\(since)") }
        return try await send(r)
    }

    public func health() async -> Bool {
        guard let (data, res) = try? await session.data(for: request("v1/health")), (res as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("true")
    }

    /// The agent's connection details (owner's Mac only).
    public func agentSetup() async throws -> AgentSetup {
        let (data, res) = try await session.data(for: request("v1/agent-setup"))
        switch (res as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(AgentSetup.self, from: data)
        case 401, 403: throw APIError.unauthorized
        case let code: throw APIError.http(code)
        }
    }

    struct ErrorBody: Decodable {
        let error: String
        let opIndex: Int?
    }

    private func send(_ r: URLRequest) async throws -> SyncResponse {
        let (data, res) = try await session.data(for: r)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return try JSONDecoder().decode(SyncResponse.self, from: data)
        case 401, 403: throw APIError.unauthorized
        case 400:
            if let e = try? JSONDecoder().decode(ErrorBody.self, from: data), let i = e.opIndex { throw APIError.badOp(index: i, code: e.error) }
            throw APIError.http(400)
        default: throw APIError.http(code)
        }
    }

    /// WebSocket request for /v1/live with the token in the header.
    public func liveRequest() -> URLRequest {
        var r = request("v1/live")
        if let u = r.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.scheme = c.scheme == "https" ? "wss" : "ws"
            r.url = c.url
        }
        return r
    }
}
