import { describe, it, expect } from "vitest";
import { api, ops, inboxId, inStore } from "./helpers";

async function stats(days = 14) {
  const r = await api(`/v1/stats?days=${days}`);
  return { status: r.status, body: (await r.json()) as any };
}

const HOUR = 3600_000;

describe("stats", () => {
  it("counts opens per day", async () => {
    await ops([{ op: "opened" }, { op: "opened" }]);
    const s = await stats();
    const today = new Date().toISOString().slice(0, 10);
    expect(s.body.opens_per_day[today]).toBe(2);
  });

  it("pct_acted counts only my actions within 48h of creation", async () => {
    const inbox = await inboxId();
    const base = Date.now() - 72 * HOUR;
    await inStore((store) => {
      const now = (t: number) => new Date(t).toISOString();
      store.db.apply("agent", { op: "create", item: { id: "a1", parent_id: inbox, position: "a0", text: "acted fast" } }, now(base));
      store.db.apply("agent", { op: "create", item: { id: "a2", parent_id: inbox, position: "a1", text: "acted late" } }, now(base));
      store.db.apply("agent", { op: "create", item: { id: "a3", parent_id: inbox, position: "a2", text: "agent ticked itself" } }, now(base));
      store.db.apply("agent", { op: "create", item: { id: "a4", parent_id: inbox, position: "a3", text: "ignored" } }, now(base));
      store.db.apply("me", { op: "complete", id: "a1", done: true }, now(base + 2 * HOUR));
      store.db.apply("me", { op: "update", id: "a2", fields: { text: "late" } }, now(base + 50 * HOUR));
      store.db.apply("agent", { op: "complete", id: "a3", done: true }, now(base + HOUR));
      // Seeing an item is not acting on it.
      store.db.apply("me", { op: "update", id: "a4", fields: { seen_at: now(base + HOUR) } }, now(base + HOUR));
    });
    const s = await stats();
    expect(s.body.agent_items).toBe(4);
    expect(s.body.agent_items_acted_within_48h).toBe(1);
    expect(s.body.pct_acted).toBe(25);
  });

  it("agent token cannot read stats", async () => {
    const r = await api("/v1/stats", {}, "agent-test-token");
    expect(r.status).toBe(403);
  });
});
