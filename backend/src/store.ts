import { DurableObject } from "cloudflare:workers";
import { Db } from "./db";
import { handleMcp } from "./mcp";
import { RateLimiter } from "./ratelimit";
import { trialStats } from "./stats";
import { Actor, ApplyResult, Change, Item, Op, OpError, SyncResponse } from "./types";

export class Store extends DurableObject<Env> {
  db: Db;
  agentLimiter = new RateLimiter(60, 60_000);

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = new Db(ctx.storage.sql);
    ctx.blockConcurrencyWhile(async () => this.db.init());
    // Answered by the runtime without waking the object, so idle sockets stay cheap.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  applyOps(actor: Actor, ops: Op[]): ApplyResult {
    const before = this.db.version();
    let index = 0;
    try {
      this.ctx.storage.transactionSync(() => {
        const now = new Date().toISOString();
        for (index = 0; index < ops.length; index++) this.db.apply(actor, ops[index], now);
      });
    } catch (e) {
      if (e instanceof OpError) return { ok: false, error: e.code, message: e.message, opIndex: index };
      throw e;
    }
    const after = this.db.version();
    if (after !== before) this.afterCommit(after);
    return { ok: true, version: after, items: this.db.since(before) };
  }

  /** Hook for live updates (Task 3). */
  protected afterCommit(version: number) {
    const frame = JSON.stringify({ version });
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(frame);
      } catch {
        // A dead socket is dropped by the runtime; the Mac pulls on reconnect.
      }
    }
  }

  /** The Worker forwards authenticated agent requests to /mcp here. */
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/mcp") return handleMcp(this, req, this.env.AGENT_NAME ?? "the agent", this.env.TIMEZONE || undefined);
    if (url.pathname === "/v1/live") {
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return new Response("not found", { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, msg: string | ArrayBuffer) {
    if (msg === "ping") ws.send("pong");
  }

  async webSocketClose(ws: WebSocket, code: number) {
    try {
      ws.close(code, "closing");
    } catch {}
  }

  sync(since: number): SyncResponse {
    return { version: this.db.version(), items: this.db.since(since) };
  }

  changesSince(since: number, limit: number): Change[] {
    return this.db.changesSince(since, limit);
  }

  stats(days: number) {
    return trialStats(this.db, days);
  }

  getItem(id: string): Item | null {
    return this.db.get(id);
  }

  children(parentId: string | null): Item[] {
    return this.db.children(parentId);
  }
}
