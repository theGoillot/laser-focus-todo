export type Actor = "me" | "agent";

export interface Item {
  id: string;
  parent_id: string | null;
  position: string;
  text: string;
  note: string | null;
  completed_at: string | null;
  collapsed: boolean;
  /** Things-style "When": the day it shows in Today (YYYY-MM-DD, the owner's local day). */
  when_date: string | null;
  deadline: string | null;
  /** List style (top-level items): an SF Symbol name and a palette color. */
  icon: string | null;
  color: string | null;
  created_by: Actor;
  seen_at: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  version: number;
}

export type UpdatableFields = Partial<Pick<Item, "text" | "note" | "collapsed" | "seen_at" | "when_date" | "deadline" | "icon" | "color">>;

export type Op =
  | { op: "create"; item: Pick<Item, "id" | "parent_id" | "position" | "text"> & Partial<Pick<Item, "note" | "when_date" | "deadline" | "icon" | "color">> }
  | { op: "update"; id: string; fields: UpdatableFields }
  | { op: "move"; id: string; parent_id: string | null; position: string }
  | { op: "complete"; id: string; done: boolean }
  | { op: "delete"; id: string }
  | { op: "restore"; id: string }
  | { op: "opened" };

export interface Change {
  version: number;
  item_id: string | null;
  actor: Actor;
  op: Op["op"];
  at: string;
  fields: Record<string, unknown> | null;
  previous: Record<string, unknown> | null;
}

export interface SyncResponse {
  version: number;
  items: Item[];
  /** Echoed by POST /v1/ops?since=N: items cover everything newer than N, so the client can skip its pull. */
  since?: number;
}

export type ApplyResult = ({ ok: true } & SyncResponse) | { ok: false; error: string; opIndex: number; message: string };

export const TEXT_MAX = 2000;
export const NOTE_MAX = 10000;

export class OpError extends Error {
  constructor(public code: string, message?: string) {
    super(message ?? code);
  }
}

/** A real calendar day as YYYY-MM-DD. */
export function isDay(v: unknown): v is string {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(v + "T00:00:00Z");
  return !isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

export const COLORS = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "brown", "gray"] as const;
export function isIcon(v: unknown): v is string {
  return typeof v === "string" && /^[a-z0-9]+(\.[a-z0-9]+)*$/.test(v) && v.length <= 48;
}
