import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { api, AGENT } from "./helpers";

describe("agent setup", () => {
  it("the Mac gets everything an agent needs to connect", async () => {
    const res = await api("/v1/agent-setup");
    expect(res.status).toBe(200);
    const b = (await res.json()) as any;
    expect(b.mcp_url).toBe("https://todo.test/mcp");
    expect(typeof b.agent_name).toBe("string");
    expect(b.agent_name.length).toBeGreaterThan(0);
    expect(b.env).toEqual({ LASER_FOCUS_MCP_URL: "https://todo.test/mcp", LASER_FOCUS_API_KEY: AGENT });
    expect(b.mcp_config.mcpServers["laser-focus"]).toEqual({
      type: "http", url: "https://todo.test/mcp", headers: { Authorization: `Bearer ${AGENT}` },
    });
  });

  it("the agent cannot read its own setup (Mac only)", async () => {
    expect((await api("/v1/agent-setup", {}, AGENT)).status).toBe(403);
  });

  it("the MCP server tells agents how to use it", async () => {
    const transport = new StreamableHTTPClientTransport(new URL("https://todo.test/mcp"), {
      requestInit: { headers: { Authorization: `Bearer ${AGENT}` } },
      fetch: (url, init) => SELF.fetch(url as string, init as RequestInit),
    });
    const c = new Client({ name: "t", version: "1" });
    await c.connect(transport);
    const ins = c.getInstructions() ?? "";
    expect(ins).toContain("Laser Focus");
    expect(ins).toContain("LASER_FOCUS_API_KEY");
    expect(ins).toContain("get_today");
  });
});
