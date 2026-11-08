import Foundation

/// What an agent needs to connect, as the backend's /v1/agent-setup hands it to the owner's Mac.
/// One shared place on disk (`~/.config/laser-focus/agent.env`) and one name (`LASER_FOCUS_API_KEY`) everywhere.
public struct AgentSetup: Decodable, Sendable, Equatable {
    /// The backend's AGENT_NAME (how the app labels the agent's items). Older backends omit it.
    public let agentName: String?
    public let mcpURL: String
    public let apiKey: String
    /// The standard `mcpServers` JSON for clients configured by file.
    public let mcpConfigJSON: String

    public static let keyName = "LASER_FOCUS_API_KEY"
    public static let urlName = "LASER_FOCUS_MCP_URL"

    /// `LASER_FOCUS_CONFIG_DIR` overrides the folder (QA runs never touch the real file).
    public static func envPath(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (environment["LASER_FOCUS_CONFIG_DIR"] ?? home + "/.config/laser-focus") + "/agent.env"
    }

    enum Keys: String, CodingKey { case agent_name, mcp_url, env, mcp_config }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        agentName = try c.decodeIfPresent(String.self, forKey: .agent_name)
        mcpURL = try c.decode(String.self, forKey: .mcp_url)
        let env = try c.decode([String: String].self, forKey: .env)
        guard let key = env[Self.keyName] else {
            throw DecodingError.dataCorruptedError(forKey: .env, in: c, debugDescription: "missing \(Self.keyName)")
        }
        apiKey = key
        let raw = try c.decode(JSONValue.self, forKey: .mcp_config)
        let data = try JSONSerialization.data(withJSONObject: raw.any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        mcpConfigJSON = String(decoding: data, as: UTF8.self)
    }

    /// The file the agent reads: key and address, nothing else.
    public var envFile: String {
        "# Laser Focus: the agent's key and MCP address (not the Mac key).\n\(Self.keyName)=\(apiKey)\n\(Self.urlName)=\(mcpURL)\n"
    }

    /// What the owner pastes into the agent's chat. Points at the file; never contains the key itself.
    public func instructions(agentName: String, envPath: String) -> String {
        """
        Connect to Laser Focus, my to-do list, as an MCP server.
        - Address: \(mcpURL) (Streamable HTTP)
        - Key: read \(Self.keyName) from the file \(envPath) on my Mac (it also has \(Self.urlName)).
        - Send the header Authorization: Bearer <\(Self.keyName)> on every request.
        Then call list_lists and tell me what you see. You are \(agentName) there; the server explains its tools when you connect.
        """
    }
}

/// Minimal JSON tree, to re-encode the backend's config object as-is.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case let .string(s): s
        case let .number(n): n
        case let .bool(b): b
        case .null: NSNull()
        case let .array(a): a.map(\.any)
        case let .object(o): o.mapValues(\.any)
        }
    }
}
