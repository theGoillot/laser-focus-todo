import { afterEach } from "vitest";
import { abortAllDurableObjects } from "cloudflare:test";
import { inStore } from "./helpers";

// Each test starts from an empty store (Inbox is recreated on boot) with a fresh in-memory rate limiter.
afterEach(async () => {
  await inStore((s) => s.ctx.storage.sql.exec("DELETE FROM items; DELETE FROM changes; DELETE FROM sqlite_sequence;"));
  await abortAllDurableObjects();
});
