import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import { api, AGENT, MAC } from "./helpers";

describe("auth", () => {
  it("health needs no token", async () => {
    const r = await SELF.fetch("https://todo.test/v1/health");
    expect(await r.json()).toEqual({ ok: true });
  });
  it("no token is 401", async () => {
    expect((await api("/v1/sync?since=0", {}, "")).status).toBe(401);
  });
  it("wrong token is 401", async () => {
    expect((await api("/v1/sync?since=0", {}, "nope")).status).toBe(401);
  });
  it("agent token on /v1 is 403", async () => {
    expect((await api("/v1/sync?since=0", {}, AGENT)).status).toBe(403);
  });
  it("mac token is 200", async () => {
    expect((await api("/v1/sync?since=0")).status).toBe(200);
  });
  it("token in query string is ignored", async () => {
    const r = await SELF.fetch("https://todo.test/v1/sync?since=0&token=mac-test-token");
    expect(r.status).toBe(401);
  });
  it("/mcp without a key explains how to authenticate", async () => {
    const res = await SELF.fetch("https://todo.test/mcp", { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toContain("Bearer");
    const body = (await res.json()) as any;
    expect(body.error).toBe("UNAUTHORIZED");
    expect(body.message).toContain("LASER_FOCUS_API_KEY");
    expect(body.message).toContain("Authorization: Bearer");
  });

  it("/mcp with the Mac key says to use the agent key", async () => {
    const res = await SELF.fetch("https://todo.test/mcp", { method: "POST", body: "{}", headers: { Authorization: `Bearer ${MAC}` } });
    expect(res.status).toBe(403);
    expect(((await res.json()) as any).message).toContain("LASER_FOCUS_API_KEY");
  });
});
