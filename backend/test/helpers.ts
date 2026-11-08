import { SELF } from "cloudflare:test";

export const MAC = "mac-test-token";
export const AGENT = "agent-test-token";

export async function api(path: string, init: RequestInit = {}, token = MAC) {
  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (init.body) headers.set("Content-Type", "application/json");
  return SELF.fetch(`https://todo.test${path}`, { ...init, headers });
}

export async function ops(list: unknown[], token = MAC) {
  const res = await api("/v1/ops", { method: "POST", body: JSON.stringify({ ops: list }) }, token);
  return { status: res.status, body: (await res.json()) as any };
}

export async function sync(since = 0) {
  const res = await api(`/v1/sync?since=${since}`);
  return (await res.json()) as { version: number; items: any[] };
}

export async function inboxId() {
  const s = await sync(0);
  return s.items.find((i) => i.parent_id === null && i.text === "Inbox")!.id as string;
}

import { env, runInDurableObject } from "cloudflare:test";
/** Runs fn against the single Store instance (typed loosely to keep tsc fast). */
export function inStore<R>(fn: (store: any) => R | Promise<R>): Promise<R> {
  const ns = env.STORE as any;
  const run = runInDurableObject as unknown as (stub: unknown, cb: (s: unknown) => Promise<R>) => Promise<R>;
  return run(ns.get(ns.idFromName("main")), async (s) => fn(s));
}
