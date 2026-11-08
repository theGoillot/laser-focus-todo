import Foundation
import Security

/// Where the backend lives and the Mac's bearer token.
public struct Connection: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var token: String
    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

/// Keeps the connection in the login Keychain, never on disk in plain text.
public struct TokenStore: Sendable {
    public let service: String
    let account = "connection"

    /// Defaults to the app's bundle id, so forks with their own id get their own Keychain entry.
    public init(service: String = Bundle.main.bundleIdentifier ?? "laser-focus") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> Connection? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    public func save(_ c: Connection) throws {
        let data = try JSONEncoder().encode(c)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}
