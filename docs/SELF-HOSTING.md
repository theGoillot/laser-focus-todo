# Self-hosting

Everything runs on your own free Cloudflare account and your own Mac. Nothing is shared with anyone.

## 1. Backend

```sh
cd backend
pnpm install
npx wrangler login            # opens the browser; do this yourself
cp wrangler.jsonc wrangler.local.jsonc   # optional: your Worker name, AGENT_NAME, TIMEZONE (ignored by git)
pnpm run deploy               # prints https://<name>.<your-subdomain>.workers.dev
```

First deploy on a new Cloudflare account fails with "You need a workers.dev subdomain": open
Workers & Pages in the Cloudflare dashboard once, then deploy again.

## 2. Keys

```sh
../scripts/setup-secrets.sh https://<name>.<your-subdomain>.workers.dev
```

Creates both keys, sets them on the Worker, and writes `~/.config/laser-focus/mac.env` and `agent.env` (owner-only).
Run it again any time to rotate.

## 3. Mac app

```sh
cd mac
cp Local.xcconfig.example Local.xcconfig   # your Apple team id and a bundle id of your own
make install                                # builds Release, installs /Applications/Laser Focus.app, opens it
```

Paste the Worker URL and `LASER_FOCUS_MAC_KEY` (from `mac.env`) into the setup screen. Without a team id the app
builds ad-hoc signed, which works on your own Mac.

## 4. Your agent

Settings > Agent > Set Up Agent, then paste into your agent. See [MCP.md](MCP.md).

## Optional: import from Workflowy

Workflowy > Export all > OPML, then:

```sh
cd scripts && pnpm install
MAC_TOKEN=... API_URL=https://... pnpm tsx import-opml.ts ~/Downloads/workflowy.opml
```

## Updating

`git pull`, then `cd backend && pnpm run deploy` (always before the app when both changed), then `cd mac && make install`.
