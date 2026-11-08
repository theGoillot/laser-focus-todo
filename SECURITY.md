# Security

## Reporting

Please report vulnerabilities privately: GitHub > Security > "Report a vulnerability" on this repo. Don't open a
public issue. You'll get an answer within a few days.

## What is secret, and where it lives

| Secret | Where | Never in |
| --- | --- | --- |
| Mac key (`MAC_TOKEN`) | Cloudflare Worker secret, your Mac's Keychain, `~/.config/laser-focus/mac.env` | git, chats, agents |
| Agent key (`AGENT_TOKEN` / `LASER_FOCUS_API_KEY`) | Cloudflare Worker secret, `~/.config/laser-focus/agent.env`, your agent's config | git, public chats |
| Apple team id, bundle id | `mac/Local.xcconfig` (ignored) | git |
| Your Worker name / vars | `backend/wrangler.local.jsonc` (ignored) | git |

Files under `~/.config/laser-focus/` are created owner-only (chmod 600).

## Design choices

- Two keys. The agent key only reaches `/mcp`: it can't delete, can't edit or move lists, and is limited to 60 writes
  a minute. The Mac key can't call `/mcp` (each key has one job).
- Keys travel only in the `Authorization` header, never in URLs. Comparison is constant-time on SHA-256 digests.
- Item text and notes are treated as data in every MCP tool description, to blunt prompt injection through your list.
- Debug builds have a local QA channel (distributed notifications). Release builds (`make install`) don't contain it.
- This repo and its CI hold no credentials. CI runs with a read-only token, so pull requests have nothing to steal.
- `scripts/check-secrets.sh` (pre-commit, pre-push, CI) blocks keys and personal files; gitleaks runs in CI.

## If a key leaks

Run `scripts/setup-secrets.sh <worker url>` (rotates both), paste the new Mac key in the app, then
Settings > Agent > Set Up Agent.
