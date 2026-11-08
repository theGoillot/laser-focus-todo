import { Db } from "./db";

const H48 = 48 * 3600_000;

/** Trial metrics: how often the panel opens, and whether I act on what the agent adds. */
export function trialStats(db: Db, days: number, now = Date.now()) {
  const since = now - days * 86400_000;
  const changes = db.changesSince(0, 1_000_000);
  const opens_per_day: Record<string, number> = {};
  for (const c of changes) {
    if (c.op !== "opened" || Date.parse(c.at) < since) continue;
    const day = c.at.slice(0, 10);
    opens_per_day[day] = (opens_per_day[day] ?? 0) + 1;
  }

  const agentItems = db.all(true).filter((i) => i.created_by === "agent" && Date.parse(i.created_at) >= since);
  const acted = agentItems.filter((item) => {
    const deadline = Date.parse(item.created_at) + H48;
    return changes.some((c) => {
      if (c.item_id !== item.id || c.actor !== "me" || Date.parse(c.at) > deadline) return false;
      if (c.op === "update") return Boolean(c.fields && ("text" in c.fields || "note" in c.fields));
      return c.op === "complete" || c.op === "move" || c.op === "delete";
    });
  }).length;

  return {
    days,
    opens_per_day,
    agent_items: agentItems.length,
    agent_items_acted_within_48h: acted,
    pct_acted: agentItems.length ? Math.round((acted / agentItems.length) * 100) : 0,
  };
}
