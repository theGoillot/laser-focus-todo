import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import { AGENT, MAC, ops, inboxId } from "./helpers";

async function openSocket(token = MAC) {
  const res = await SELF.fetch("https://todo.test/v1/live", { headers: { Upgrade: "websocket", Authorization: `Bearer ${token}` } });
  return res;
}

function nextFrame(ws: WebSocket, ms = 1000) {
  return new Promise<string>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("no frame")), ms);
    ws.addEventListener("message", (e) => {
      clearTimeout(t);
      resolve(String(e.data));
    }, { once: true });
  });
}

describe("live", () => {
  it("rejects without the mac token", async () => {
    expect((await openSocket(AGENT)).status).toBe(403);
    const r = await SELF.fetch("https://todo.test/v1/live", { headers: { Upgrade: "websocket" } });
    expect(r.status).toBe(401);
  });

  it("agent write nudges socket", async () => {
    const res = await openSocket();
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    const frame = nextFrame(ws);
    const add = await SELF.fetch("https://todo.test/mcp", {
      method: "POST",
      headers: { Authorization: `Bearer ${AGENT}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "add_item", arguments: { text: "hi", list: "Inbox" } } }),
    });
    expect(add.status).toBe(200);
    const msg = JSON.parse(await frame);
    expect(msg.version).toBeGreaterThan(0);
    ws.close();
  });

  it("mac write nudges socket too", async () => {
    const ws = (await openSocket()).webSocket!;
    ws.accept();
    const frame = nextFrame(ws);
    await ops([{ op: "create", item: { id: "z", parent_id: await inboxId(), position: "a0", text: "z" } }]);
    expect(JSON.parse(await frame).version).toBeGreaterThan(0);
    ws.close();
  });

  it("answers ping with pong", async () => {
    const ws = (await openSocket()).webSocket!;
    ws.accept();
    const frame = nextFrame(ws);
    ws.send("ping");
    expect(await frame).toBe("pong");
    ws.close();
  });
});
