/**
 * One-time import of a Workflowy OPML export into the backend.
 *   MAC_TOKEN=... API_URL=https://... pnpm tsx import-opml.ts ~/Downloads/workflowy.opml
 * Top-level Workflowy items become lists. A top-level item whose name matches an existing list
 * (for example Inbox) is merged into that list instead of creating a duplicate.
 */
import { XMLParser } from "fast-xml-parser";
import { generateKeyBetween } from "fractional-indexing";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

export interface ImportNode {
  text: string;
  note?: string;
  done: boolean;
  children: ImportNode[];
}

export type Op =
  | { op: "create"; item: { id: string; parent_id: string | null; position: string; text: string; note: string | null } }
  | { op: "complete"; id: string; done: boolean };

const TEXT_MAX = 2000;
const NOTE_MAX = 10000;

const decode = (s: string) =>
  s
    .replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .trim();

export function parseOpml(xml: string): ImportNode[] {
  const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "", processEntities: true, isArray: (name) => name === "outline" });
  const doc = parser.parse(xml);
  const walk = (outlines: any[] | undefined): ImportNode[] =>
    (outlines ?? []).map((o) => ({
      text: decode(String(o.text ?? "")),
      note: o._note ? decode(String(o._note)) : undefined,
      done: o._complete === "true" || o._complete === true,
      children: walk(o.outline),
    }));
  return walk(doc?.opml?.body?.outline);
}

/** Create ops parents-first, in document order. Positions start after `after` under `parentId`. */
export function toOps(nodes: ImportNode[], parentId: string | null, after: string | null = null): Op[] {
  const ops: Op[] = [];
  const walk = (pid: string | null, list: ImportNode[], start: string | null) => {
    let prev = start;
    for (const n of list) {
      prev = generateKeyBetween(prev, null);
      const id = randomUUID();
      let text = n.text;
      let note = n.note ?? null;
      if (text.length > TEXT_MAX) {
        note = [text, note].filter(Boolean).join("\n\n");
        text = text.slice(0, TEXT_MAX);
      }
      if (note && note.length > NOTE_MAX) note = note.slice(0, NOTE_MAX);
      ops.push({ op: "create", item: { id, parent_id: pid, position: prev, text, note } });
      if (n.done) ops.push({ op: "complete", id, done: true });
      walk(id, n.children, null);
    }
  };
  walk(parentId, nodes, after);
  return ops;
}

export function countNodes(nodes: ImportNode[]): number {
  return nodes.reduce((n, x) => n + 1 + countNodes(x.children), 0);
}

async function main() {
  const [file] = process.argv.slice(2);
  const api = process.env.API_URL ?? "http://localhost:8787";
  const token = process.env.MAC_TOKEN;
  if (!file || !token) {
    console.error("usage: MAC_TOKEN=... API_URL=... pnpm tsx import-opml.ts <file.opml>");
    process.exit(1);
  }
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const nodes = parseOpml(readFileSync(file, "utf8"));
  const state = (await (await fetch(`${api}/v1/sync?since=0`, { headers })).json()) as { items: any[] };
  const tops = state.items.filter((i) => i.parent_id === null && !i.deleted_at).sort((a, b) => (a.position < b.position ? -1 : 1));

  const ops: Op[] = [];
  const fresh: ImportNode[] = [];
  for (const n of nodes) {
    const match = tops.find((t) => t.text.trim().toLowerCase() === n.text.trim().toLowerCase());
    if (match) {
      const kids = state.items.filter((i) => i.parent_id === match.id && !i.deleted_at).sort((a, b) => (a.position < b.position ? -1 : 1));
      ops.push(...toOps(n.children, match.id, kids.at(-1)?.position ?? null));
    } else fresh.push(n);
  }
  ops.push(...toOps(fresh, null, tops.at(-1)?.position ?? null));

  for (let i = 0; i < ops.length; i += 200) {
    const res = await fetch(`${api}/v1/ops`, { method: "POST", headers, body: JSON.stringify({ ops: ops.slice(i, i + 200) }) });
    if (!res.ok) throw new Error(`batch ${i / 200} failed: ${res.status} ${await res.text()}`);
    process.stdout.write(".");
  }
  console.log(`\nImported ${countNodes(nodes)} outline items (${ops.length} ops).`);
}

if (process.argv[1]?.endsWith("import-opml.ts")) main().catch((e) => {
  console.error(e);
  process.exit(1);
});
