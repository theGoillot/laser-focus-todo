import { describe, it, expect } from "vitest";
import { ops, sync, inboxId } from "./helpers";

const id = () => crypto.randomUUID();

describe("when and deadline", () => {
  it("new items have no dates", async () => {
    const x = id();
    await ops([{ op: "create", item: { id: x, parent_id: await inboxId(), position: "a0", text: "A" } }]);
    const it = (await sync(0)).items.find((i) => i.id === x);
    expect(it).toMatchObject({ when_date: null, deadline: null });
  });

  it("create can carry dates", async () => {
    const x = id();
    const r = await ops([{ op: "create", item: { id: x, parent_id: await inboxId(), position: "a0", text: "A", when_date: "2026-11-08", deadline: "2026-11-10" } }]);
    expect(r.status).toBe(200);
    const it = (await sync(0)).items.find((i) => i.id === x);
    expect(it).toMatchObject({ when_date: "2026-11-08", deadline: "2026-11-10" });
  });

  it("update sets and clears dates", async () => {
    const x = id();
    await ops([{ op: "create", item: { id: x, parent_id: await inboxId(), position: "a0", text: "A" } }]);
    await ops([{ op: "update", id: x, fields: { when_date: "2026-11-07", deadline: "2026-12-01" } }]);
    let it = (await sync(0)).items.find((i) => i.id === x);
    expect(it).toMatchObject({ when_date: "2026-11-07", deadline: "2026-12-01" });
    await ops([{ op: "update", id: x, fields: { when_date: null } }]);
    it = (await sync(0)).items.find((i) => i.id === x);
    expect(it).toMatchObject({ when_date: null, deadline: "2026-12-01" });
  });

  it("rejects a bad date", async () => {
    const x = id();
    await ops([{ op: "create", item: { id: x, parent_id: await inboxId(), position: "a0", text: "A" } }]);
    const r = await ops([{ op: "update", id: x, fields: { deadline: "tomorrow" } }]);
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("BAD_DATE");
    const r2 = await ops([{ op: "update", id: x, fields: { when_date: "2026-02-30" } }]);
    expect(r2.body.error).toBe("BAD_DATE");
  });
});
