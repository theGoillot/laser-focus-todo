# Contributing

Laser Focus is built by makers, many of us with AI coding agents. Both kinds of pull requests are welcome.

## The loop

1. Fork, then `git config core.hooksPath .githooks` (blocks commits that contain keys or personal files).
2. Pick something from [docs/ROADMAP.md](docs/ROADMAP.md) or an issue, or fix what annoys you.
3. Write the failing test first, then the change ([AGENTS.md](AGENTS.md) explains where things live).
4. Run everything: `cd backend && pnpm test && pnpm typecheck`, `cd mac && make test`, `cd scripts && pnpm vitest run`.
5. Open a PR: what you changed, why, how you checked it (screenshots for UI). CI runs the same tests and a secret scan.

## With an AI agent

Tell it: "Read AGENTS.md, then <your change>. Tests first, run all suites, no keys in commits." Review its diff like
you would a colleague's. If it touched the UI, run the app (`cd mac && make build`) and look.

## Taste

- Calm and fast beats feature-rich. Every new setting needs a reason.
- Keyboard first. Every action has a shortcut and an undo.
- The agent is a guest: it can add and suggest, never delete or reorganize your lists.
- Short, plain words in the UI.

## Not wanted

Analytics, accounts, anything that sends data somewhere other than the user's own backend.
