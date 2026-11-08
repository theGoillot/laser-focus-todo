import XCTest
@testable import TodoCore

final class TokenStoreTests: XCTestCase {
    let keychain = TokenStore(service: "laser-focus.tests.\(UUID().uuidString)")

    override func tearDown() { keychain.clear() }

    func testSaveLoadClear() throws {
        XCTAssertNil(keychain.load())
        try keychain.save(Connection(baseURL: URL(string: "https://x.workers.dev")!, token: "secret"))
        XCTAssertEqual(keychain.load(), Connection(baseURL: URL(string: "https://x.workers.dev")!, token: "secret"))
        try keychain.save(Connection(baseURL: URL(string: "https://y.workers.dev")!, token: "s2"))
        XCTAssertEqual(keychain.load()?.token, "s2")
        keychain.clear()
        XCTAssertNil(keychain.load())
    }
}
