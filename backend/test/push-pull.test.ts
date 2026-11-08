import { describe, it, expect } from "vitest";
import { api, inboxId, inStore, sync } from "./helpers";

const id = () => crypto.randomUUID();

async function push(list: unknown[], since?: number) {
  const q = since === undefined ? "" : `?since=${since}`;
  const res = await api(`/v1/ops${q}`, { method: "POST", body: JSON.stringify({ ops: list }) });
  return { status: res.status, body: (await res.json()) as any };
}

describe("push answers the pull (one round trip per edit)", () => {
  it("with ?since, returns everything newer than the Mac's cursor, including other actors' changes", async () => {
    const inbox = await inboxId();
    const cursor = (await sync(0)).version;
    const agentId = id();
    await inStore((s: any) => s.applyOps("agent", [{ op: "create", item: { id: agentId, parent_id: inbox, position: "a0", text: "From agent" } }]));
    const mine = id();
    const r = await push([{ op: "create", item: { id: mine, parent_id: inbox, position: "a1", text: "Mine" } }], cursor);
    expect(r.status).toBe(200);
    expect(r.body.since).toBe(cursor);
    expect(r.body.items.map((i: any) => i.id).sort()).toEqual([agentId, mine].sort());
    expect(r.body.version).toBe((await sync(0)).version);
  });

  it("without ?since, keeps the old answer (only this batch) and no since echo", async () => {
    const inbox = await inboxId();
    await inStore((s: any) => s.applyOps("agent", [{ op: "create", item: { id: id(), parent_id: inbox, position: "a0", text: "Other" } }]));
    const mine = id();
    const r = await push([{ op: "create", item: { id: mine, parent_id: inbox, position: "a1", text: "Mine" } }]);
    expect(r.body.items.map((i: any) => i.id)).toEqual([mine]);
    expect(r.body.since).toBeUndefined();
  });

  it("rejects a bad since", async () => {
    const r = await push([], -1);
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("BAD_SINCE");
  });

  it("an empty batch with ?since is a plain pull", async () => {
    const cursor = (await sync(0)).version;
    const inbox = await inboxId();
    const x = id();
    await inStore((s: any) => s.applyOps("agent", [{ op: "create", item: { id: x, parent_id: inbox, position: "a0", text: "New" } }]));
    const r = await push([], cursor);
    expect(r.body.items.map((i: any) => i.id)).toEqual([x]);
  });
});
