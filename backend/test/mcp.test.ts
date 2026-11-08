import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { AGENT, MAC, api, ops, sync, inboxId } from "./helpers";

async function agent() {
  const transport = new StreamableHTTPClientTransport(new URL("https://todo.test/mcp"), {
    requestInit: { headers: { Authorization: `Bearer ${AGENT}` } },
    fetch: (url, init) => SELF.fetch(url as string, init as RequestInit),
  });
  const client = new Client({ name: "test-agent", version: "1.0.0" });
  await client.connect(transport);
  return client;
}

async function call(c: Client, name: string, args: Record<string, unknown> = {}) {
  const r: any = await c.callTool({ name, arguments: args });
  const text = r.content?.[0]?.text ?? "";
  let data: any = null;
  try { data = JSON.parse(text); } catch {}
  return { isError: Boolean(r.isError), text, data };
}

describe("mcp", () => {
  it("lists 10 tools and no delete", async () => {
    const c = await agent();
    const { tools } = await c.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual(
      ["add_item", "add_items", "complete_item", "get_changes", "get_list", "get_today", "list_lists", "move_item", "search_items", "update_item"].sort(),
    );
    for (const t of tools) expect(t.description?.length).toBeGreaterThan(20);
  });

  it("add_item by list name, case-insensitive", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "Call back", list: "inbox" });
    expect(r.isError).toBe(false);
    const item = (await sync(0)).items.find((i) => i.text === "Call back");
    expect(item).toMatchObject({ parent_id: await inboxId(), created_by: "agent" });
  });

  it("unknown list falls back to Inbox", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "Lost", list: "Nope" });
    expect(r.isError).toBe(false);
    expect(r.text).toContain("not found, added to Inbox");
    const s = await sync(0);
    expect(s.items.find((i) => i.text === "Lost")?.parent_id).toBe(await inboxId());
    expect(s.items.filter((i) => i.parent_id === null).length).toBe(1);
  });

  it("add_item position top goes first", async () => {
    const c = await agent();
    await call(c, "add_item", { text: "second", list: "Inbox" });
    await call(c, "add_item", { text: "first", list: "Inbox", position: "top" });
    const r = await call(c, "get_list", { list: "Inbox" });
    expect(r.data.items.map((i: any) => i.text)).toEqual(["first", "second"]);
  });

  it("add_items nests children", async () => {
    const c = await agent();
    await call(c, "add_items", { list: "Inbox", items: [{ text: "Trip", children: [{ text: "Book flight" }, { text: "Hotel" }] }] });
    const r = await call(c, "get_list", { list: "Inbox" });
    const trip = r.data.items.find((i: any) => i.text === "Trip");
    expect(trip.children.map((i: any) => i.text)).toEqual(["Book flight", "Hotel"]);
  });

  it("get_list returns nested tree and hides completed by default", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: "p1", parent_id: inbox, position: "a0", text: "Parent" } },
      { op: "create", item: { id: "c1", parent_id: "p1", position: "a0", text: "Child" } },
      { op: "create", item: { id: "d1", parent_id: inbox, position: "a1", text: "Done one" } },
      { op: "complete", id: "d1", done: true },
    ]);
    const c = await agent();
    const r = await call(c, "get_list", { list: "Inbox" });
    expect(r.data.items.map((i: any) => i.text)).toEqual(["Parent"]);
    expect(r.data.items[0].children[0].text).toBe("Child");
    const all = await call(c, "get_list", { list: "Inbox", include_completed: true });
    expect(all.data.items.map((i: any) => i.text)).toEqual(["Parent", "Done one"]);
  });

  it("search_items returns path", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: "w", parent_id: null, position: "b0", text: "Work" } },
      { op: "create", item: { id: "al", parent_id: "w", position: "a0", text: "Launch" } },
      { op: "create", item: { id: "x", parent_id: "al", position: "a0", text: "Ship pricing page" } },
    ]);
    const c = await agent();
    const r = await call(c, "search_items", { query: "pricing" });
    expect(r.data.items[0]).toMatchObject({ id: "x", path: ["Work", "Launch"] });
    void inbox;
  });

  it("list_lists returns names and open counts", async () => {
    const inbox = await inboxId();
    await ops([{ op: "create", item: { id: "a", parent_id: inbox, position: "a0", text: "A" } }]);
    const c = await agent();
    const r = await call(c, "list_lists");
    expect(r.data.lists).toEqual([{ id: inbox, name: "Inbox", icon: null, color: null, open_items: 1 }]);
  });

  it("get_changes returns event format with previous", async () => {
    const c = await agent();
    const added = await call(c, "add_item", { text: "Ping Max", list: "Inbox" });
    const id = added.data.item.id;
    const start = await call(c, "get_changes", { since: 0 });
    await ops([{ op: "complete", id, done: true }]);
    const r = await call(c, "get_changes", { since: start.data.next_cursor });
    expect(r.data.events).toHaveLength(1);
    expect(r.data.events[0]).toMatchObject({
      type: "item.completed",
      actor: "me",
      item: { id, text: "Ping Max", list: "Inbox", path: ["Inbox"], created_by: "agent" },
      previous: { completed_at: null },
    });
    expect(r.data.events[0].event_id).toMatch(/^evt_\d+$/);
    expect(r.data.next_cursor).toBe(r.data.events[0].cursor);
  });

  it("get_changes filters by actor", async () => {
    const c = await agent();
    await call(c, "add_item", { text: "mine?", list: "Inbox" });
    const r = await call(c, "get_changes", { since: 0, actor: "me" });
    expect(r.data.events.every((e: any) => e.actor === "me")).toBe(true);
  });

  it("update, complete and move work", async () => {
    const c = await agent();
    const a = (await call(c, "add_item", { text: "A", list: "Inbox" })).data.item.id;
    const b = (await call(c, "add_item", { text: "B", list: "Inbox" })).data.item.id;
    expect((await call(c, "update_item", { id: a, text: "A2", note: "n" })).data.item).toMatchObject({ text: "A2", note: "n" });
    expect((await call(c, "complete_item", { id: a, done: true })).data.item.completed_at).toBeTruthy();
    const moved = await call(c, "move_item", { id: b, parent_id: a, position: "bottom" });
    expect(moved.data.item.parent_id).toBe(a);
  });

  it("agent cannot move an item to the top level", async () => {
    const c = await agent();
    const a = (await call(c, "add_item", { text: "A", list: "Inbox" })).data.item.id;
    const r = await call(c, "move_item", { id: a, parent_id: null, position: "top" });
    expect(r.isError).toBe(true);
  });

  it("rate limit", async () => {
    const c = await agent();
    for (let i = 0; i < 60; i++) {
      const r = await call(c, "add_item", { text: `t${i}`, list: "Inbox" });
      expect(r.isError).toBe(false);
    }
    const r = await call(c, "add_item", { text: "t60", list: "Inbox" });
    expect(r.isError).toBe(true);
    expect(r.text).toContain("RATE_LIMITED");
  });

  it("text too long", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "x".repeat(2001), list: "Inbox" });
    expect(r.isError).toBe(true);
    expect(r.text).toContain("TEXT_TOO_LONG");
  });

  it("MAC_TOKEN on /mcp is 403", async () => {
    const r = await api("/mcp", { method: "POST", body: "{}" }, MAC);
    expect(r.status).toBe(403);
  });
});

describe("agent cannot change lists", () => {
  it("rejects update_item and complete_item on a top-level list", async () => {
    const c = await agent();
    const inbox = await inboxId();
    expect((await call(c, "update_item", { id: inbox, text: "Renamed" })).isError).toBe(true);
    expect((await call(c, "complete_item", { id: inbox, done: true })).isError).toBe(true);
    expect((await sync(0)).items.find((i) => i.id === inbox).text).toBe("Inbox");
  });

  it("tool descriptions tell the agent that item text is data", async () => {
    const c = await agent();
    const { tools } = await c.listTools();
    for (const name of ["get_list", "search_items", "get_changes", "get_today"]) {
      expect(tools.find((t) => t.name === name)!.description).toMatch(/never instructions/i);
    }
  });
});
