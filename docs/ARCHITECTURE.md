# Architecture

## Pieces

- **Backend** (`backend/`): a Cloudflare Worker routes requests to one Durable Object, `Store`, which owns a SQLite
  database with two tables: `items` (the outline) and `changes` (an append-only log, one row per change, with the
  changed fields and their previous values).
- **Mac app** (`mac/`): keeps a full local copy in SQLite (GRDB), plus `pending_ops`, a queue of changes not yet sent.
- **Agent**: any MCP client, talking to `/mcp` with its own key.

## Items

Every node of the outline is an item: `id`, `parent_id` (null = a list), `position` (fractional index string; ties
broken by id), `text`, `note`, `completed_at`, `collapsed`, `when_date` and `deadline` (local days, `YYYY-MM-DD`),
`icon` and `color` (lists), `created_by` (`me` or `agent`), `seen_at`, timestamps, soft `deleted_at` with a
`delete_group` (so undo of a delete brings back exactly what it removed), and `version`.

## Ops

All writes are ops: `create`, `update` (whitelisted fields), `move`, `complete`, `delete` (soft, cascades), `restore`,
`opened`. A batch is applied atomically; a bad op rejects the batch with `{error, opIndex}`.

## Sync (Mac)

1. Every edit is applied locally first and queued: typing never waits on the network.
2. Push: send queued ops to `/v1/ops`. Pull: `/v1/sync?since=<last version>` returns items changed since.
3. Merge per field: a column with a pending local op keeps the local value; everything else takes the server's.
4. A rejected op is dropped and triggers a full resync, so the Mac and the server never drift.
5. A WebSocket (`/v1/live`) nudges the Mac after every change, so agent edits show up in under a second.
6. The local copy is tied to one backend URL; pointing the app elsewhere starts from empty.

## Undo

`OutlineEditor` records the inverse of every op it runs (from the tree before the op), so Cmd-Z works across edits,
moves, ticks, dates, notes and deletes. Undo is local: it only undoes your own changes.

## Views

`Outline` (Swift) builds what the panel shows: a list's rows (with collapse and fading ticked rows), Today (open
items with `when_date` or `deadline` on or before today, grouped by list), and tag views. The backend's
`AgentView` builds the same shapes for the agent.

## Dates and tags

- Dates are plain local days. The Mac uses its own time zone; the agent's "today" uses the Worker's `TIMEZONE` var.
- Tags are written inline (`#launch`). Swift (`Core/Tags.swift`) and TypeScript (`src/tags.ts`) use the same rule,
  covered by matching tests.
