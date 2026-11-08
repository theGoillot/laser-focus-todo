import { describe, it, expect } from "vitest";
import { parseOpml, toOps } from "./import-opml";

const OPML = `<?xml version="1.0"?>
<opml version="2.0"><head><title>Workflowy</title></head><body>
  <outline text="Work">
    <outline text="Launch &amp; pricing" _note="ask Max">
      <outline text="Draft page" _complete="true"/>
    </outline>
  </outline>
  <outline text="Home"/>
</body></opml>`;

describe("parseOpml", () => {
  it("keeps nesting, notes, done and decodes entities", () => {
    const nodes = parseOpml(OPML);
    expect(nodes.map((n) => n.text)).toEqual(["Work", "Home"]);
    const launch = nodes[0].children[0];
    expect(launch).toMatchObject({ text: "Launch & pricing", note: "ask Max", done: false });
    expect(launch.children[0]).toMatchObject({ text: "Draft page", done: true, children: [] });
  });

  it("handles a single top-level outline", () => {
    expect(parseOpml(`<opml><body><outline text="Only"/></body></opml>`).map((n) => n.text)).toEqual(["Only"]);
  });

  it("strips Workflowy html in text", () => {
    expect(parseOpml(`<opml><body><outline text="&lt;b&gt;Bold&lt;/b&gt; move"/></body></opml>`)[0].text).toBe("Bold move");
  });
});

describe("toOps", () => {
  it("creates parents before children, in order, with increasing positions", () => {
    const ops = toOps(parseOpml(OPML), null);
    const creates = ops.filter((o) => o.op === "create") as any[];
    expect(creates.map((c) => c.item.text)).toEqual(["Work", "Launch & pricing", "Draft page", "Home"]);
    const [work, launch, draft, home] = creates.map((c) => c.item);
    expect(work.parent_id).toBeNull();
    expect(launch.parent_id).toBe(work.id);
    expect(draft.parent_id).toBe(launch.id);
    expect(work.position < home.position).toBe(true);
    expect(launch.note).toBe("ask Max");
  });

  it("adds a complete op for done nodes, after their create", () => {
    const ops = toOps(parseOpml(OPML), null);
    const i = ops.findIndex((o) => o.op === "complete");
    expect(ops[i]).toMatchObject({ op: "complete", done: true });
    const draftIdx = ops.findIndex((o: any) => o.op === "create" && o.item.text === "Draft page");
    expect(i).toBeGreaterThan(draftIdx);
  });

  it("truncates text over 2000 chars instead of failing the import", () => {
    const long = "x".repeat(2500);
    const ops = toOps([{ text: long, done: false, children: [] }], null) as any[];
    expect(ops[0].item.text.length).toBe(2000);
    expect(ops[0].item.note).toContain("x".repeat(500));
  });
});

describe("limits", () => {
  it("caps a long note so the batch is never rejected", () => {
    const ops = toOps([{ text: "short", note: "n".repeat(12000), done: false, children: [] }], null) as any[];
    expect(ops[0].item.note.length).toBe(10000);
  });
});
