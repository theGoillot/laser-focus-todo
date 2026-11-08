#!/bin/sh
# Runs wrangler with backend/wrangler.local.jsonc when it exists (your own Worker name and vars), else the shared
# wrangler.jsonc. Used by `pnpm dev`, `pnpm run deploy`, `pnpm tail` and setup-secrets.sh.
cd "$(dirname "$0")/../backend" || exit 1
if [ -f wrangler.local.jsonc ]; then
  exec pnpm exec wrangler "$@" --config wrangler.local.jsonc
else
  exec pnpm exec wrangler "$@"
fi
