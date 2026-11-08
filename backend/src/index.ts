import { actorFor } from "./auth";
import { Op } from "./types";
export { Store } from "./store";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const MCP_AUTH_HELP =
  "Laser Focus MCP needs the agent key. Send the header Authorization: Bearer <LASER_FOCUS_API_KEY> on every request. " +
  "On the owner's Mac the key is in ~/.config/laser-focus/agent.env (LASER_FOCUS_API_KEY=...).";

/** A sync cursor: a non-negative integer, or null when malformed. */
const cursor = (raw: string) => {
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : null;
};

export function storeFor(env: Env) {
  return env.STORE.get(env.STORE.idFromName("main"));
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/v1/health") return json({ ok: true });

    const actor = await actorFor(req, env);
    if (!actor) {
      if (url.pathname !== "/mcp") return json({ error: "UNAUTHORIZED" }, 401);
      // Agents read this: say exactly which key and which header.
      return new Response(JSON.stringify({ error: "UNAUTHORIZED", message: MCP_AUTH_HELP }), {
        status: 401,
        headers: { "Content-Type": "application/json", "WWW-Authenticate": 'Bearer realm="laser-focus"' },
      });
    }
    const store = storeFor(env);

    if (url.pathname === "/mcp") {
      if (actor !== "agent") return json({ error: "FORBIDDEN", message: "That is the Mac key. " + MCP_AUTH_HELP }, 403);
      return store.fetch(req);
    }

    if (url.pathname.startsWith("/v1/")) {
      if (actor !== "me") return json({ error: "FORBIDDEN" }, 403);

      // Everything an agent needs to connect, for the owner's Mac to hand over (Settings > Set up agent).
      if (url.pathname === "/v1/agent-setup") {
        const mcp = `${url.origin}/mcp`;
        return json({
          agent_name: env.AGENT_NAME || "Agent",
          mcp_url: mcp,
          env: { LASER_FOCUS_MCP_URL: mcp, LASER_FOCUS_API_KEY: env.AGENT_TOKEN },
          mcp_config: { mcpServers: { "laser-focus": { type: "http", url: mcp, headers: { Authorization: `Bearer ${env.AGENT_TOKEN}` } } } },
        });
      }

      if (url.pathname === "/v1/live") {
        if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return json({ error: "UPGRADE_REQUIRED" }, 426);
        return store.fetch(req);
      }
      if (url.pathname === "/v1/stats" && req.method === "GET") {
        const days = Math.min(365, Math.max(1, Number(url.searchParams.get("days") ?? "14") || 14));
        return json(await store.stats(days));
      }
      if (url.pathname === "/v1/sync" && req.method === "GET") {
        const since = cursor(url.searchParams.get("since") ?? "0");
        if (since === null) return json({ error: "BAD_SINCE" }, 400);
        return json(await store.sync(since));
      }
      if (url.pathname === "/v1/ops" && req.method === "POST") {
        let body: { ops?: Op[] };
        try {
          body = await req.json();
        } catch {
          return json({ error: "BAD_JSON" }, 400);
        }
        if (!Array.isArray(body.ops)) return json({ error: "BAD_OPS" }, 400);
        const raw = url.searchParams.get("since");
        const since = raw === null ? undefined : cursor(raw);
        if (since === null) return json({ error: "BAD_SINCE" }, 400);
        const r = await store.applyOps("me", body.ops, since);
        if (!r.ok) return json(r, 400);
        return json(r.since === undefined ? { version: r.version, items: r.items } : { version: r.version, items: r.items, since: r.since });
      }
    }
    return json({ error: "NOT_FOUND" }, 404);
  },
} satisfies ExportedHandler<Env>;
