import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { AGENT, ops, sync, inboxId } from "./helpers";
import { tagsIn, localDay } from "../src/tags";

async function agent() {
  const transport = new StreamableHTTPClientTransport(new URL("https://todo.test/mcp"), {
    requestInit: { headers: { Authorization: `Bearer ${AGENT}` } },
    fetch: (url, init) => SELF.fetch(url as string, init as RequestInit),
  });
  const client = new Client({ name: "t", version: "1" });
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
const today = () => localDay(new Date(), "America/New_York");
const plusDays = (d: string, n: number) => new Date(Date.parse(d + "T12:00:00Z") + n * 864e5).toISOString().slice(0, 10);

describe("tags", () => {
  it("finds #tags, keeps dots inside, drops trailing punctuation, lowercases", () => {
    expect(tagsIn("Call Acme #acme.io. Then #Work, and #a-b/c! not a#b")).toEqual(["acme.io", "work", "a-b/c"]);
    expect(tagsIn("#sunday Send update")).toEqual(["sunday"]);
    expect(tagsIn("no tags # here")).toEqual([]);
    expect(tagsIn("#a.#b and #c-#d")).toEqual(["a", "b", "c", "d"]);
  });
});

describe("mcp dates and tags", () => {
  it("has 10 tools including get_today", async () => {
    const { tools } = await (await agent()).listTools();
    expect(tools.map((t) => t.name)).toContain("get_today");
    expect(tools.length).toBe(10);
  });

  it("add_item with when today and a deadline", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "Pay AMEX", list: "Inbox", when: "today", deadline: "2026-12-01" });
    expect(r.isError).toBe(false);
    expect(r.data.item).toMatchObject({ when_date: today(), deadline: "2026-12-01" });
  });

  it("when tomorrow resolves in the owner's timezone", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "T", list: "Inbox", when: "tomorrow" });
    expect(r.data.item.when_date).toBe(plusDays(today(), 1));
  });

  it("rejects an unparseable when instead of dropping it", async () => {
    const c = await agent();
    const r = await call(c, "add_item", { text: "T", list: "Inbox", when: "someday soon" });
    expect(r.isError).toBe(true);
    expect(r.text).toContain("BAD_DATE");
  });

  it("update_item sets and clears when", async () => {
    const c = await agent();
    const a = await call(c, "add_item", { text: "U", list: "Inbox" });
    const id = a.data.item.id;
    expect((await call(c, "update_item", { id, when: "2026-11-20" })).data.item.when_date).toBe("2026-11-20");
    expect((await call(c, "update_item", { id, when: null })).data.item.when_date).toBe(null);
  });

  it("get_today returns open items starred for today or earlier, or due today, grouped by list", async () => {
    const inbox = await inboxId();
    const t = today();
    const mk = (id: string, text: string, extra: object) => ({ op: "create", item: { id, parent_id: inbox, position: "a" + text, text, ...extra } });
    await ops([
      mk(crypto.randomUUID(), "Star", { when_date: t }),
      mk(crypto.randomUUID(), "Old", { when_date: plusDays(t, -3) }),
      mk(crypto.randomUUID(), "Due", { deadline: t }),
      mk(crypto.randomUUID(), "Later", { when_date: plusDays(t, 2) }),
      mk(crypto.randomUUID(), "Plain", {}),
    ]);
    const done = crypto.randomUUID();
    await ops([mk(done, "Done", { when_date: t }), { op: "complete", id: done, done: true }]);
    const r = await call(await agent(), "get_today");
    expect(r.data.today).toBe(t);
    const texts = r.data.lists.flatMap((l: any) => l.items.map((i: any) => i.text)).sort();
    expect(texts).toEqual(["Due", "Old", "Star"]);
    expect(r.data.lists[0].name).toBe("Inbox");
  });

  it("search_items by tag matches whole tags only", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: crypto.randomUUID(), parent_id: inbox, position: "a1", text: "Wire #acme.io deal" } },
      { op: "create", item: { id: crypto.randomUUID(), parent_id: inbox, position: "a2", text: "Mention acme.io without tag" } },
      { op: "create", item: { id: crypto.randomUUID(), parent_id: inbox, position: "a3", text: "#acme.iopany other" } },
    ]);
    const r = await call(await agent(), "search_items", { tag: "#acme.io" });
    expect(r.data.items.map((i: any) => i.text)).toEqual(["Wire #acme.io deal"]);
    expect(r.data.items[0].tags).toEqual(["acme.io"]);
  });

  it("get_list shows dates and tags", async () => {
    const c = await agent();
    await call(c, "add_item", { text: "Ping #hiring", list: "Inbox", deadline: "2026-12-24" });
    const r = await call(c, "get_list", { list: "Inbox" });
    const it = r.data.items.find((i: any) => i.text === "Ping #hiring");
    expect(it).toMatchObject({ deadline: "2026-12-24", when_date: null, tags: ["hiring"] });
  });
});
