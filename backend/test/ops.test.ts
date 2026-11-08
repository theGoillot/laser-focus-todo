import { describe, it, expect } from "vitest";
import { ops, sync, inboxId, inStore } from "./helpers";

const id = () => crypto.randomUUID();

describe("ops and sync", () => {
  it("Inbox exists on first boot", async () => {
    const s = await sync(0);
    const tops = s.items.filter((i) => i.parent_id === null && !i.deleted_at);
    expect(tops.map((i) => i.text)).toContain("Inbox");
  });

  it("create then sync returns item", async () => {
    const inbox = await inboxId();
    const x = id();
    const r = await ops([{ op: "create", item: { id: x, parent_id: inbox, position: "a0", text: "Buy milk" } }]);
    expect(r.status).toBe(200);
    const s = await sync(0);
    const item = s.items.find((i) => i.id === x);
    expect(item).toMatchObject({ text: "Buy milk", created_by: "me", parent_id: inbox, completed_at: null });
    expect(item.version).toBeGreaterThan(0);
  });

  it("per-field merge keeps both fields", async () => {
    const inbox = await inboxId();
    const x = id();
    await ops([{ op: "create", item: { id: x, parent_id: inbox, position: "a0", text: "A" } }]);
    await ops([{ op: "update", id: x, fields: { text: "B" } }]);
    await inStore((store: any) => {
      store.applyOps("agent", [{ op: "complete", id: x, done: true }]);
    });
    const item = (await sync(0)).items.find((i) => i.id === x);
    expect(item.text).toBe("B");
    expect(item.completed_at).not.toBeNull();
  });

  it("delete cascades to subtree", async () => {
    const inbox = await inboxId();
    const p = id(), c1 = id(), c2 = id();
    await ops([
      { op: "create", item: { id: p, parent_id: inbox, position: "a0", text: "P" } },
      { op: "create", item: { id: c1, parent_id: p, position: "a0", text: "C1" } },
      { op: "create", item: { id: c2, parent_id: c1, position: "a0", text: "C2" } },
    ]);
    const before = (await sync(0)).version;
    await ops([{ op: "delete", id: p }]);
    const after = await sync(before);
    for (const x of [p, c1, c2]) expect(after.items.find((i) => i.id === x)?.deleted_at).toBeTruthy();
    const changes = await inStore((store: any) =>
      store.changesSince(before, 100),
    );
    expect(changes.filter((c: any) => c.op === "delete").map((c: any) => c.item_id).sort()).toEqual([p, c1, c2].sort());
  });

  it("changes row stores fields and previous", async () => {
    const inbox = await inboxId();
    const x = id();
    await ops([{ op: "create", item: { id: x, parent_id: inbox, position: "a0", text: "T" } }]);
    await ops([{ op: "complete", id: x, done: true }]);
    const changes = await inStore((store: any) =>
      store.changesSince(0, 100),
    );
    const last = changes[changes.length - 1];
    expect(last.op).toBe("complete");
    expect(last.previous).toEqual({ completed_at: null });
    expect(last.fields.completed_at).toBeTruthy();
  });

  it("sync since filters untouched items", async () => {
    const inbox = await inboxId();
    const a = id(), b = id();
    await ops([{ op: "create", item: { id: a, parent_id: inbox, position: "a0", text: "A" } }]);
    const v = (await sync(0)).version;
    await ops([{ op: "create", item: { id: b, parent_id: inbox, position: "a1", text: "B" } }]);
    const s = await sync(v);
    expect(s.items.map((i) => i.id)).toEqual([b]);
    expect(s.version).toBeGreaterThan(v);
  });

  it("text too long rejected", async () => {
    const inbox = await inboxId();
    const r = await ops([{ op: "create", item: { id: id(), parent_id: inbox, position: "a0", text: "x".repeat(2001) } }]);
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("TEXT_TOO_LONG");
  });

  it("a failing op rolls back the whole batch", async () => {
    const inbox = await inboxId();
    const ok = id();
    const r = await ops([
      { op: "create", item: { id: ok, parent_id: inbox, position: "a0", text: "fine" } },
      { op: "update", id: "missing", fields: { text: "x" } },
    ]);
    expect(r.status).toBe(400);
    expect((await sync(0)).items.find((i) => i.id === ok)).toBeUndefined();
  });

  it("opened is logged without item", async () => {
    await ops([{ op: "opened" }]);
    const changes = await inStore((store: any) =>
      store.changesSince(0, 100),
    );
    expect(changes.some((c: any) => c.op === "opened" && c.item_id === null && c.actor === "me")).toBe(true);
  });
});

describe("restore", () => {
  it("brings back a deleted subtree, but not items deleted earlier", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: "p", parent_id: inbox, position: "a0", text: "P" } },
      { op: "create", item: { id: "c", parent_id: "p", position: "a0", text: "C" } },
      { op: "create", item: { id: "old", parent_id: "p", position: "a1", text: "Old" } },
    ]);
    await ops([{ op: "delete", id: "old" }]);
    await new Promise((r) => setTimeout(r, 5));
    await ops([{ op: "delete", id: "p" }]);
    const r = await ops([{ op: "restore", id: "p" }]);
    expect(r.status).toBe(200);
    const items = (await sync(0)).items;
    expect(items.find((i) => i.id === "p").deleted_at).toBeNull();
    expect(items.find((i) => i.id === "c").deleted_at).toBeNull();
    expect(items.find((i) => i.id === "old").deleted_at).not.toBeNull();
  });
});

describe("restore groups", () => {
  it("undoing a parent delete does not bring back a child deleted separately in the same batch", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: "P", parent_id: inbox, position: "a0", text: "P" } },
      { op: "create", item: { id: "C", parent_id: "P", position: "a0", text: "C" } },
      { op: "create", item: { id: "K", parent_id: "P", position: "a1", text: "K" } },
    ]);
    await ops([{ op: "delete", id: "C" }, { op: "delete", id: "P" }]);
    await ops([{ op: "restore", id: "P" }]);
    const items = (await sync(0)).items;
    expect(items.find((i) => i.id === "P").deleted_at).toBeNull();
    expect(items.find((i) => i.id === "K").deleted_at).toBeNull();
    expect(items.find((i) => i.id === "C").deleted_at).not.toBeNull();
  });

  it("a move into a parent loop is rejected even with an existing loop in data", async () => {
    const inbox = await inboxId();
    await ops([
      { op: "create", item: { id: "A", parent_id: inbox, position: "a0", text: "A" } },
      { op: "create", item: { id: "B", parent_id: "A", position: "a0", text: "B" } },
    ]);
    const r = await ops([{ op: "move", id: "A", parent_id: "B", position: "a0" }]);
    expect(r.body.error).toBe("CYCLE");
  });
});
