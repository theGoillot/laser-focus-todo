import { Actor } from "./types";

async function digest(s: string) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

async function same(a: string, b: string) {
  if (!a || !b) return false;
  const [x, y] = await Promise.all([digest(a), digest(b)]);
  return crypto.subtle.timingSafeEqual(x, y);
}

/** Resolves the bearer token in the Authorization header to an actor. Tokens in URLs are never read. */
export async function actorFor(req: Request, env: Env): Promise<Actor | null> {
  const h = req.headers.get("Authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  if (!m) return null;
  const token = m[1].trim();
  if (await same(token, env.MAC_TOKEN)) return "me";
  if (await same(token, env.AGENT_TOKEN)) return "agent";
  return null;
}
