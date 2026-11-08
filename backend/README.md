# Backend

One Cloudflare Worker and one Durable Object (`Store`) that holds your outline in SQLite, pushes live updates to the Mac over a WebSocket, and serves an MCP endpoint your agent uses.

## Run locally

```sh
pnpm install
pnpm dev          # http://localhost:8787, tokens come from .dev.vars
pnpm test         # runs inside the Workers runtime
```

`.dev.vars` (gitignored):

```
MAC_TOKEN=mac-dev-token
AGENT_TOKEN=agent-dev-token
```

## Deploy

```sh
npx wrangler login                       # once, opens the browser
pnpm run deploy                          # NOT `pnpm deploy` (that is pnpm's workspace command)
../scripts/setup-secrets.sh https://laser-focus.<your-subdomain>.workers.dev
curl -s https://laser-focus.<your-subdomain>.workers.dev/v1/health   # {"ok":true}
```

`setup-secrets.sh` creates both keys, sets them as Worker secrets (`MAC_TOKEN`, `AGENT_TOKEN`) and saves them where
everything else looks for them, owner-only (chmod 600):

| File | Variables | For |
| --- | --- | --- |
| `~/.config/laser-focus/mac.env` | `LASER_FOCUS_MAC_KEY`, `LASER_FOCUS_URL` | the Mac app's setup screen |
| `~/.config/laser-focus/agent.env` | `LASER_FOCUS_API_KEY`, `LASER_FOCUS_MCP_URL` | the agent |

Running it again rotates both keys (the Mac and the agent must reconnect). The agent's display name is the
`AGENT_NAME` var in `wrangler.jsonc` (default `Agent`); "today" for the agent uses the `TIMEZONE` var.

## Connect your agent

Easiest: in the Mac app, **Settings > Agent > Set Up Agent**. It fetches the agent's key from the backend
(`GET /v1/agent-setup`, Mac key only), writes `~/.config/laser-focus/agent.env` and copies instructions to paste
into the agent. **Copy MCP Config (JSON)** gives the standard `mcpServers` block for agents configured by file:

```json
{ "mcpServers": { "laser-focus": { "type": "http", "url": "https://.../mcp",
  "headers": { "Authorization": "Bearer <LASER_FOCUS_API_KEY>" } } } }
```

On connect the server sends instructions (what Laser Focus is, auth, Today/dates/tags, limits). A request without
the key gets a 401 that names `LASER_FOCUS_API_KEY`, the header, and where the file lives, so an agent can fix
itself.

## API

| Method | Path | Token | Does |
| --- | --- | --- | --- |
| GET | `/v1/health` | none | `{"ok":true}` |
| GET | `/v1/sync?since=N` | Mac | Items changed after version N, plus the current version |
| POST | `/v1/ops` | Mac | `{ops:[...]}` applied atomically. A bad op returns 400 `{error, opIndex}` |
| GET | `/v1/live` | Mac | WebSocket. Sends `{"version":N}` after every change. `ping` gets `pong` |
| GET | `/v1/agent-setup` | Mac | The agent's MCP URL, key (`LASER_FOCUS_API_KEY`) and `mcpServers` config |
| POST | `/mcp` | Agent | MCP tools: list_lists, get_list, get_today, search_items, get_changes, add_item, add_items, update_item, complete_item, move_item |

Rules: the agent token cannot use `/v1/*` and has no delete tool. Agent writes are capped at 60 a minute. Text is capped at 2,000 characters, notes at 10,000. Deletes are soft and cascade to children.
