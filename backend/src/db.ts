import { generateKeyBetween } from "fractional-indexing";
import { Actor, COLORS, Change, Item, NOTE_MAX, Op, OpError, TEXT_MAX, UpdatableFields, isDay, isIcon } from "./types";

type Row = Record<string, SqlStorageValue>;

export const SCHEMA = `
CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  position TEXT NOT NULL,
  text TEXT NOT NULL,
  note TEXT,
  completed_at TEXT,
  collapsed INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL,
  seen_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  version INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS items_tree ON items(parent_id, position, id);
CREATE INDEX IF NOT EXISTS items_version ON items(version);
CREATE TABLE IF NOT EXISTS changes (
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id TEXT,
  actor TEXT NOT NULL,
  op TEXT NOT NULL,
  at TEXT NOT NULL,
  fields TEXT,
  previous TEXT
);
CREATE INDEX IF NOT EXISTS changes_item ON changes(item_id);
`;

export function toItem(r: Row): Item {
  return {
    id: r.id as string,
    parent_id: (r.parent_id as string | null) ?? null,
    position: r.position as string,
    text: r.text as string,
    note: (r.note as string | null) ?? null,
    completed_at: (r.completed_at as string | null) ?? null,
    collapsed: Boolean(r.collapsed),
    when_date: (r.when_date as string | null) ?? null,
    deadline: (r.deadline as string | null) ?? null,
    icon: (r.icon as string | null) ?? null,
    color: (r.color as string | null) ?? null,
    created_by: r.created_by as Actor,
    seen_at: (r.seen_at as string | null) ?? null,
    created_at: r.created_at as string,
    updated_at: r.updated_at as string,
    deleted_at: (r.deleted_at as string | null) ?? null,
    version: r.version as number,
  };
}

function toChange(r: Row): Change {
  return {
    version: r.version as number,
    item_id: (r.item_id as string | null) ?? null,
    actor: r.actor as Actor,
    op: r.op as Change["op"],
    at: r.at as string,
    fields: r.fields ? JSON.parse(r.fields as string) : null,
    previous: r.previous ? JSON.parse(r.previous as string) : null,
  };
}

/** All SQL for the store. Every method assumes it runs inside a storage transaction when it writes. */
export class Db {
  constructor(private sql: SqlStorage) {}

  init() {
    this.sql.exec(SCHEMA);
    // v2: deletes are grouped so a restore brings back exactly what one delete removed.
    const cols = this.sql.exec("PRAGMA table_info(items)").toArray().map((r) => r.name);
    if (!cols.includes("delete_group")) this.sql.exec("ALTER TABLE items ADD COLUMN delete_group TEXT");
    // v3: Things-style dates.
    if (!cols.includes("when_date")) this.sql.exec("ALTER TABLE items ADD COLUMN when_date TEXT");
    if (!cols.includes("deadline")) this.sql.exec("ALTER TABLE items ADD COLUMN deadline TEXT");
    // v4: list icon and color.
    if (!cols.includes("icon")) this.sql.exec("ALTER TABLE items ADD COLUMN icon TEXT");
    if (!cols.includes("color")) this.sql.exec("ALTER TABLE items ADD COLUMN color TEXT");
    const inbox = this.sql.exec("SELECT id FROM items WHERE parent_id IS NULL AND text = 'Inbox' AND deleted_at IS NULL").toArray();
    if (inbox.length === 0) {
      const now = new Date().toISOString();
      const first = this.sql.exec("SELECT position FROM items WHERE parent_id IS NULL ORDER BY position, id LIMIT 1").toArray()[0];
      const pos = generateKeyBetween(null, (first?.position as string) ?? null);
      this.createRow({ id: crypto.randomUUID(), parent_id: null, position: pos, text: "Inbox" }, "me", now);
    }
  }

  version(): number {
    const r = this.sql.exec("SELECT MAX(version) AS v FROM changes").one();
    return (r.v as number | null) ?? 0;
  }

  get(id: string): Item | null {
    const r = this.sql.exec("SELECT * FROM items WHERE id = ?", id).toArray()[0];
    return r ? toItem(r) : null;
  }

  live(id: string): Item {
    const it = this.get(id);
    if (!it || it.deleted_at) throw new OpError("NOT_FOUND", `item ${id} not found`);
    return it;
  }

  children(parentId: string | null, includeDeleted = false): Item[] {
    const where = parentId === null ? "parent_id IS NULL" : "parent_id = ?";
    const del = includeDeleted ? "" : " AND deleted_at IS NULL";
    const args = parentId === null ? [] : [parentId];
    return this.sql.exec(`SELECT * FROM items WHERE ${where}${del} ORDER BY position, id`, ...args).toArray().map(toItem);
  }

  all(includeDeleted = false): Item[] {
    const del = includeDeleted ? "" : " WHERE deleted_at IS NULL";
    return this.sql.exec(`SELECT * FROM items${del} ORDER BY position, id`).toArray().map(toItem);
  }

  since(version: number): Item[] {
    return this.sql.exec("SELECT * FROM items WHERE version > ? ORDER BY version", version).toArray().map(toItem);
  }

  changesSince(version: number, limit: number): Change[] {
    return this.sql.exec("SELECT * FROM changes WHERE version > ? ORDER BY version LIMIT ?", version, limit).toArray().map(toChange);
  }

  private log(itemId: string | null, actor: Actor, op: Change["op"], at: string, fields: object | null, previous: object | null): number {
    this.sql.exec(
      "INSERT INTO changes (item_id, actor, op, at, fields, previous) VALUES (?, ?, ?, ?, ?, ?)",
      itemId, actor, op, at, fields ? JSON.stringify(fields) : null, previous ? JSON.stringify(previous) : null,
    );
    return this.version();
  }

  private createRow(item: Extract<Op, { op: "create" }>["item"], actor: Actor, now: string) {
    const v = this.log(item.id, actor, "create", now, { ...item }, null);
    this.sql.exec(
      `INSERT INTO items (id, parent_id, position, text, note, completed_at, collapsed, created_by, seen_at, created_at, updated_at, deleted_at, version, when_date, deadline, icon, color)
       VALUES (?, ?, ?, ?, ?, NULL, 0, ?, NULL, ?, ?, NULL, ?, ?, ?, ?, ?)`,
      item.id, item.parent_id, item.position, item.text, item.note ?? null, actor, now, now, v, item.when_date ?? null, item.deadline ?? null,
      item.icon ?? null, item.color ?? null,
    );
  }

  private setFields(id: string, fields: Record<string, unknown>, version: number, now: string) {
    const keys = Object.keys(fields);
    const sets = keys.map((k) => `${k} = ?`).join(", ");
    const vals = keys.map((k) => (typeof fields[k] === "boolean" ? (fields[k] ? 1 : 0) : fields[k]));
    this.sql.exec(`UPDATE items SET ${sets}, updated_at = ?, version = ? WHERE id = ?`, ...(vals as SqlStorageValue[]), now, version, id);
  }

  private isDescendant(candidate: string, ancestor: string): boolean {
    let cur: string | null = candidate;
    const seen = new Set<string>();
    while (cur && !seen.has(cur)) {
      seen.add(cur);
      if (cur === ancestor) return true;
      cur = this.get(cur)?.parent_id ?? null;
    }
    return false;
  }

  apply(actor: Actor, op: Op, now: string) {
    switch (op.op) {
      case "create": {
        const it = op.item;
        if (typeof it?.id !== "string" || !it.id) throw new OpError("BAD_OP", "create needs item.id");
        checkText(it.text, it.note);
        checkDates(it);
        checkStyle(it);
        if (this.get(it.id)) return; // idempotent retry
        if (it.parent_id !== null) this.live(it.parent_id);
        if (typeof it.position !== "string" || !it.position) throw new OpError("BAD_OP", "create needs position");
        const row: Extract<Op, { op: "create" }>["item"] = { id: it.id, parent_id: it.parent_id, position: it.position, text: it.text, note: it.note ?? null };
        if (it.when_date) row.when_date = it.when_date;
        if (it.deadline) row.deadline = it.deadline;
        if (it.icon) row.icon = it.icon;
        if (it.color) row.color = it.color;
        this.createRow(row, actor, now);
        return;
      }
      case "update": {
        const cur = this.live(op.id);
        const allowed: (keyof UpdatableFields)[] = ["text", "note", "collapsed", "seen_at", "when_date", "deadline", "icon", "color"];
        const fields: Record<string, unknown> = {};
        for (const k of allowed) if (op.fields && k in op.fields) fields[k] = (op.fields as any)[k];
        if (Object.keys(fields).length === 0) throw new OpError("BAD_OP", "update needs fields");
        checkDates(fields);
        checkStyle(fields);
        if ("text" in fields || "note" in fields) checkText((fields.text as string) ?? cur.text, (fields.note as string | null) ?? null);
        const previous: Record<string, unknown> = {};
        for (const k of Object.keys(fields)) previous[k] = (cur as any)[k];
        const v = this.log(op.id, actor, "update", now, fields, previous);
        this.setFields(op.id, fields, v, now);
        return;
      }
      case "move": {
        const cur = this.live(op.id);
        if (op.parent_id !== null) {
          this.live(op.parent_id);
          if (this.isDescendant(op.parent_id, op.id)) throw new OpError("CYCLE", "cannot move an item inside itself");
        }
        if (typeof op.position !== "string" || !op.position) throw new OpError("BAD_OP", "move needs position");
        const fields = { parent_id: op.parent_id, position: op.position };
        const v = this.log(op.id, actor, "move", now, fields, { parent_id: cur.parent_id, position: cur.position });
        this.setFields(op.id, fields, v, now);
        return;
      }
      case "complete": {
        const cur = this.live(op.id);
        const completed_at = op.done ? cur.completed_at ?? now : null;
        const v = this.log(op.id, actor, "complete", now, { completed_at }, { completed_at: cur.completed_at });
        this.setFields(op.id, { completed_at }, v, now);
        return;
      }
      case "delete": {
        const root = this.get(op.id);
        if (!root || root.deleted_at) return; // already gone: idempotent
        const group = crypto.randomUUID();
        const stack = [root];
        while (stack.length) {
          const it = stack.pop()!;
          const v = this.log(it.id, actor, "delete", now, { deleted_at: now }, { deleted_at: null });
          this.setFields(it.id, { deleted_at: now, delete_group: group }, v, now);
          stack.push(...this.children(it.id));
        }
        return;
      }
      case "restore": {
        // Undo of a delete: brings back the item and the descendants that went with it (same deleted_at).
        const root = this.get(op.id);
        if (!root || !root.deleted_at) return;
        if (root.parent_id !== null) this.live(root.parent_id);
        const group = this.sql.exec("SELECT delete_group FROM items WHERE id = ?", root.id).one().delete_group as string | null;
        const stack = [root];
        while (stack.length) {
          const it = stack.pop()!;
          const v = this.log(it.id, actor, "restore", now, { deleted_at: null }, { deleted_at: it.deleted_at });
          this.setFields(it.id, { deleted_at: null, delete_group: null }, v, now);
          const kids = this.sql
            .exec("SELECT * FROM items WHERE parent_id = ? AND deleted_at IS NOT NULL AND delete_group IS ?", it.id, group)
            .toArray()
            .map(toItem);
          stack.push(...kids);
        }
        return;
      }
      case "opened": {
        this.log(null, actor, "opened", now, null, null);
        return;
      }
      default:
        throw new OpError("BAD_OP", `unknown op ${(op as any)?.op}`);
    }
  }
}

function checkText(text: unknown, note: unknown) {
  if (typeof text !== "string") throw new OpError("BAD_OP", "text must be a string");
  if (text.length > TEXT_MAX) throw new OpError("TEXT_TOO_LONG", `text is over ${TEXT_MAX} characters`);
  if (note != null && (typeof note !== "string" || note.length > NOTE_MAX)) throw new OpError("NOTE_TOO_LONG", `note is over ${NOTE_MAX} characters`);
}

function checkDates(f: { when_date?: unknown; deadline?: unknown }) {
  for (const k of ["when_date", "deadline"] as const) {
    const v = f[k];
    if (v != null && !isDay(v)) throw new OpError("BAD_DATE", `${k} must be a YYYY-MM-DD day or null`);
  }
}

function checkStyle(f: { icon?: unknown; color?: unknown }) {
  if (f.icon != null && !isIcon(f.icon)) throw new OpError("BAD_STYLE", "icon must be an SF Symbol name like briefcase.fill");
  if (f.color != null && !(COLORS as readonly string[]).includes(f.color as string)) throw new OpError("BAD_STYLE", `color must be one of ${COLORS.join(", ")}`);
}
