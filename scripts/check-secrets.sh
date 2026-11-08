#!/bin/sh
# Refuses commits/pushes that would publish keys or personal data.
#   scripts/check-secrets.sh          check the staged changes (pre-commit hook)
#   scripts/check-secrets.sh --all    check every tracked file (pre-push hook, CI)
# Extra private words (your email, team id, client names...) go one per line in
# ~/.config/laser-focus/private-words: that file stays on your Mac, so the list itself is never published.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
if [ "${1:-}" = "--all" ]; then FILES=$(git ls-files --cached --others --exclude-standard); else FILES=$(git diff --cached --name-only --diff-filter=ACMR); fi
[ -z "$FILES" ] && exit 0
fail=0
say() { echo "check-secrets: $*" >&2; fail=1; }

# 1. Files that must never be committed.
for f in $FILES; do
  case "$f" in
    *.dev.vars|*.env|.env|.env.*|*/.env.*|mac/Local.xcconfig|backend/wrangler.local.jsonc|*.p12|*.pem|*.key|*.mobileprovision)
      case "$f" in *.example) ;; *) say "blocked file: $f" ;; esac ;;
  esac
done

# 2. Things that look like keys.
PATTERNS='[0-9a-f]{64}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-(ant|proj)-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[A-Za-z0-9-]{10,}'
for f in $FILES; do
  [ -f "$f" ] || continue
  case "$f" in *pnpm-lock.yaml|*.png|*.jpg|*.icns) continue ;; esac
  if grep -nEI "$PATTERNS" "$f" >/dev/null 2>&1; then say "possible key in $f: $(grep -nEIo "$PATTERNS" "$f" | head -1 | cut -c1-24)..."; fi
done

# 3. Your private words.
WORDS="$HOME/.config/laser-focus/private-words"
if [ -f "$WORDS" ]; then
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    case "$w" in \#*) continue ;; esac
    for f in $FILES; do
      [ -f "$f" ] || continue
      case "$f" in *.png|*.jpg|*.icns) continue ;; esac
      if grep -qiwF -- "$w" "$f" 2>/dev/null; then say "private word \"$w\" in $f"; fi
    done
  done < "$WORDS"
fi

[ $fail -eq 0 ] || { echo "check-secrets: blocked. Remove the items above (or move them to an ignored file)." >&2; exit 1; }
exit 0
