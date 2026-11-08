import { describe, it, expect } from "vitest";
import { ops, sync, inboxId } from "./helpers";

describe("list icon and color", () => {
  it("new items have no style", async () => {
    const inbox = (await sync(0)).items.find((i) => i.parent_id === null)!;
    expect(inbox).toMatchObject({ icon: null, color: null });
  });

  it("a list can be created and updated with an icon and a color", async () => {
    const id = crypto.randomUUID();
    const r = await ops([{ op: "create", item: { id, parent_id: null, position: "b0", text: "Travel", icon: "airplane", color: "teal" } }]);
    expect(r.status).toBe(200);
    expect((await sync(0)).items.find((i) => i.id === id)).toMatchObject({ icon: "airplane", color: "teal" });
    await ops([{ op: "update", id, fields: { icon: "briefcase.fill", color: null } }]);
    expect((await sync(0)).items.find((i) => i.id === id)).toMatchObject({ icon: "briefcase.fill", color: null });
  });

  it("rejects unknown colors and odd icon names", async () => {
    const inbox = await inboxId();
    const r = await ops([{ op: "update", id: inbox, fields: { color: "chartreuse" } }]);
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("BAD_STYLE");
    const r2 = await ops([{ op: "update", id: inbox, fields: { icon: "<script>" } }]);
    expect(r2.body.error).toBe("BAD_STYLE");
  });
});
