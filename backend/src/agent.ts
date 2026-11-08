import { generateKeyBetween } from "fractional-indexing";
import { Db } from "./db";
import { Change, Item, Op, OpError } from "./types";
import { tagsIn } from "./tags";

export interface TreeNode {
  id: string;
  text: string;
  note: string | null;
  completed: boolean;
  when_date: string | null;
  deadline: string | null;
  tags: string[];
  created_by: Item["created_by"];
  children: TreeNode[];
}

export interface AgentEvent {
  event_id: string;
  type: string;
  actor: Change["actor"];
  at: string;
  cursor: number;
  item: (Omit<Item, "version"> & { list: string | null; path: string[] }) | null;
  previous: Record<string, unknown> | null;
}

const EVENT_TYPE: Record<string, string> = {
  create: "item.created",
  update: "item.updated",
  move: "item.moved",
  complete: "item.completed",
  delete: "item.deleted",
  restore: "item.restored",
};

/** Read and write helpers shaped for the agent. Pure functions over Db, so they run inside the Store. */
export class AgentView {
  constructor(private db: Db) {}

  lists() {
    return this.db.children(null).map((l) => ({ id: l.id, name: l.text, icon: l.icon, color: l.color, open_items: this.countOpen(l.id) }));
  }

  private countOpen(id: string): number {
    let n = 0;
    for (const c of this.db.children(id)) if (!c.completed_at) n += 1 + this.countOpen(c.id);
    return n;
  }

  /** Finds a top-level list by id or case-insensitive name. */
  findList(ref: string): Item | null {
    const tops = this.db.children(null);
    return tops.find((l) => l.id === ref) ?? tops.find((l) => l.text.trim().toLowerCase() === ref.trim().toLowerCase()) ?? null;
  }

  inbox(): Item {
    const it = this.findList("Inbox");
    if (!it) throw new OpError("NO_INBOX", "Inbox is missing");
    return it;
  }

  tree(parentId: string, includeCompleted: boolean): TreeNode[] {
    return this.db
      .children(parentId)
      .filter((c) => includeCompleted || !c.completed_at)
      .map((c) => ({
        id: c.id,
        text: c.text,
        note: c.note,
        completed: Boolean(c.completed_at),
        when_date: c.when_date,
        deadline: c.deadline,
        tags: tagsIn(c.text),
        created_by: c.created_by,
        children: this.tree(c.id, includeCompleted),
      }));
  }

  /** Ancestor texts from the top-level list down to the parent (the item itself excluded). */
  path(item: Item): string[] {
    const out: string[] = [];
    const seen = new Set<string>();
    let cur = item.parent_id ? this.db.get(item.parent_id) : null;
    while (cur && !seen.has(cur.id)) {
      seen.add(cur.id);
      out.unshift(cur.text);
      cur = cur.parent_id ? this.db.get(cur.parent_id) : null;
    }
    return out;
  }

  rootOf(item: Item): Item {
    let cur = item;
    const seen = new Set<string>([item.id]);
    while (cur.parent_id) {
      const p = this.db.get(cur.parent_id);
      if (!p || seen.has(p.id)) break;
      seen.add(p.id);
      cur = p;
    }
    return cur;
  }

  search(query: string, listId?: string, tag?: string) {
    const q = query.trim().toLowerCase();
    const t = tag?.trim().replace(/^#/, "").toLowerCase();
    if (!q && !t) return [];
    return this.db
      .all()
      .filter((i) => i.parent_id !== null)
      .filter((i) => !q || i.text.toLowerCase().includes(q) || (i.note ?? "").toLowerCase().includes(q))
      .filter((i) => !t || tagsIn(i.text).includes(t))
      .filter((i) => !listId || this.rootOf(i).id === listId)
      .slice(0, 50)
      .map((i) => this.brief(i));
  }

  brief(i: Item) {
    return {
      id: i.id, text: i.text, note: i.note, completed: Boolean(i.completed_at),
      when_date: i.when_date, deadline: i.deadline, tags: tagsIn(i.text), path: this.path(i),
    };
  }

  /** Things-style Today: open items starred for today or earlier, or due by today, grouped by list in list order. */
  today(day: string) {
    const lists = this.db.children(null);
    const hits = this.db
      .all()
      .filter((i) => i.parent_id !== null && !i.completed_at)
      .filter((i) => (i.when_date !== null && i.when_date <= day) || (i.deadline !== null && i.deadline <= day));
    return lists
      .map((l) => ({ id: l.id, name: l.text, items: hits.filter((i) => this.rootOf(i).id === l.id).map((i) => this.brief(i)) }))
      .filter((g) => g.items.length > 0);
  }

  events(since: number, opts: { actor?: "me" | "agent"; listId?: string; limit: number }) {
    const out: AgentEvent[] = [];
    let cursor = since;
    // Scan in pages so filters do not starve the limit.
    for (;;) {
      const page = this.db.changesSince(cursor, 500);
      if (page.length === 0) break;
      for (const c of page) {
        cursor = c.version;
        if (c.op === "opened" || !c.item_id) continue;
        if (opts.actor && c.actor !== opts.actor) continue;
        const item = this.db.get(c.item_id);
        if (!item) continue;
        if (opts.listId && this.rootOf(item).id !== opts.listId) continue;
        out.push(this.toEvent(c, item));
        if (out.length >= opts.limit) return { events: out, next_cursor: cursor };
      }
    }
    return { events: out, next_cursor: cursor };
  }

  toEvent(c: Change, item: Item): AgentEvent {
    const { version: _v, ...rest } = item;
    const root = this.rootOf(item);
    return {
      event_id: `evt_${c.version}`,
      type: EVENT_TYPE[c.op] ?? `item.${c.op}`,
      actor: c.actor,
      at: c.at,
      cursor: c.version,
      item: { ...rest, list: root.id === item.id ? null : root.text, path: item.parent_id ? this.path(item) : [] },
      previous: c.previous,
    };
  }

  /** Position key for a new child at the top or bottom of `parentId`. */
  edgePosition(parentId: string, where: "top" | "bottom"): string {
    const kids = this.db.children(parentId, true);
    if (kids.length === 0) return generateKeyBetween(null, null);
    return where === "top" ? generateKeyBetween(null, kids[0].position) : generateKeyBetween(kids[kids.length - 1].position, null);
  }

  /** Checks that `id` is a live item under list `listId` (or the list itself). */
  assertInList(id: string, listId: string) {
    const it = this.db.live(id);
    if (this.rootOf(it).id !== listId) throw new OpError("WRONG_LIST", `item ${id} is not in that list`);
    return it;
  }
}

export interface NewNode {
  text: string;
  note?: string;
  when?: string;
  deadline?: string;
  children?: NewNode[];
}

/** Flattens a nested add into create ops, parents before children, in order. */
export function nestedCreates(
  view: AgentView, parentId: string, nodes: NewNode[], where: "top" | "bottom",
  day: (v: string | undefined, field: string) => string | null | undefined = () => undefined,
): Op[] {
  const ops: Op[] = [];
  const walk = (pid: string, list: NewNode[], first: string | null, last: string | null) => {
    const keys = generateNKeys(first, last, list.length);
    list.forEach((n, i) => {
      const id = crypto.randomUUID();
      const item: Extract<Op, { op: "create" }>["item"] = { id, parent_id: pid, position: keys[i], text: n.text, note: n.note ?? null };
      const w = day(n.when, "when");
      const d = day(n.deadline, "deadline");
      if (w) item.when_date = w;
      if (d) item.deadline = d;
      ops.push({ op: "create", item });
      if (n.children?.length) walk(id, n.children, null, null);
    });
  };
  const kids = view["db"].children(parentId, true);
  if (where === "top") walk(parentId, nodes, null, kids[0]?.position ?? null);
  else walk(parentId, nodes, kids[kids.length - 1]?.position ?? null, null);
  return ops;
}

function generateNKeys(a: string | null, b: string | null, n: number): string[] {
  const out: string[] = [];
  let prev = a;
  for (let i = 0; i < n; i++) {
    prev = generateKeyBetween(prev, b);
    out.push(prev);
  }
  return out;
}

export function countNodes(nodes: NewNode[]): number {
  return nodes.reduce((n, x) => n + 1 + countNodes(x.children ?? []), 0);
}
