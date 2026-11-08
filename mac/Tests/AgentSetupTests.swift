import XCTest
@testable import TodoCore

final class AgentSetupTests: XCTestCase {
    let json = #"{"mcp_url":"https://x.dev/mcp","env":{"LASER_FOCUS_MCP_URL":"https://x.dev/mcp","LASER_FOCUS_API_KEY":"abc123"},"mcp_config":{"mcpServers":{"laser-focus":{"type":"http","url":"https://x.dev/mcp","headers":{"Authorization":"Bearer abc123"}}}}}"#

    func testDecodesAndBuildsTheEnvFile() throws {
        let s = try JSONDecoder().decode(AgentSetup.self, from: Data(json.utf8))
        XCTAssertEqual(s.apiKey, "abc123")
        XCTAssertNil(s.agentName)
        let named = try JSONDecoder().decode(AgentSetup.self, from: Data(json.replacingOccurrences(of: "{\"mcp_url\"", with: "{\"agent_name\":\"Agent\",\"mcp_url\"").utf8))
        XCTAssertEqual(named.agentName, "Agent")
        XCTAssertEqual(s.envFile, "# Laser Focus: the agent's key and MCP address (not the Mac key).\nLASER_FOCUS_API_KEY=abc123\nLASER_FOCUS_MCP_URL=https://x.dev/mcp\n")
    }

    func testInstructionsPointToTheFileAndNeverContainTheKey() throws {
        let s = try JSONDecoder().decode(AgentSetup.self, from: Data(json.utf8))
        let text = s.instructions(agentName: "Agent", envPath: "/Users/me/.config/laser-focus/agent.env")
        XCTAssertTrue(text.contains("/Users/me/.config/laser-focus/agent.env"))
        XCTAssertTrue(text.contains("LASER_FOCUS_API_KEY"))
        XCTAssertTrue(text.contains("https://x.dev/mcp"))
        XCTAssertTrue(text.contains("Authorization: Bearer"))
        XCTAssertFalse(text.contains("abc123"))
    }

    func testMcpConfigIsPrettyJSONWithTheHeader() throws {
        let s = try JSONDecoder().decode(AgentSetup.self, from: Data(json.utf8))
        let obj = try JSONSerialization.jsonObject(with: Data(s.mcpConfigJSON.utf8)) as! [String: Any]
        let server = (obj["mcpServers"] as! [String: Any])["laser-focus"] as! [String: Any]
        XCTAssertEqual((server["headers"] as! [String: String])["Authorization"], "Bearer abc123")
    }

    func testEnvPathIsTheSharedLocation() {
        XCTAssertEqual(AgentSetup.envPath(home: "/Users/me", environment: [:]), "/Users/me/.config/laser-focus/agent.env")
        XCTAssertEqual(AgentSetup.envPath(home: "/Users/me", environment: ["LASER_FOCUS_CONFIG_DIR": "/tmp/qa"]), "/tmp/qa/agent.env")
    }
}
