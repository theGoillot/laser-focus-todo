#!/bin/sh
# Creates (or rotates) both keys in one go, so they always land in the same places with the same names:
#   - Cloudflare Worker secrets MAC_TOKEN and AGENT_TOKEN
#   - ~/.config/laser-focus/mac.env    LASER_FOCUS_MAC_KEY  (paste into the app's setup screen)
#   - ~/.config/laser-focus/agent.env  LASER_FOCUS_API_KEY  + LASER_FOCUS_MCP_URL (what the agent reads)
# Rotating logs the Mac out and disconnects the agent: re-paste the Mac key, then Settings > Set Up <agent>.
# Usage: scripts/setup-secrets.sh https://menubar-todo.<subdomain>.workers.dev
set -eu
URL="${1:?usage: setup-secrets.sh <worker url>}"
URL="${URL%/}"
DIR="$HOME/.config/laser-focus"
umask 077
mkdir -p "$DIR"
MAC=$(openssl rand -hex 32)
AGENT=$(openssl rand -hex 32)
W="$(dirname "$0")/wrangler.sh"
printf '%s' "$MAC" | sh "$W" secret put MAC_TOKEN >/dev/null
printf '%s' "$AGENT" | sh "$W" secret put AGENT_TOKEN >/dev/null
printf '# Laser Focus: the Mac key (setup screen). Never give it to an agent.\nLASER_FOCUS_MAC_KEY=%s\nLASER_FOCUS_URL=%s\n' "$MAC" "$URL" > "$DIR/mac.env"
printf "# Laser Focus: the agent's key and MCP address (not the Mac key).\nLASER_FOCUS_API_KEY=%s\nLASER_FOCUS_MCP_URL=%s/mcp\n" "$AGENT" "$URL" > "$DIR/agent.env"
chmod 600 "$DIR/mac.env" "$DIR/agent.env"
echo "Keys set on the Worker and saved to $DIR (mac.env, agent.env)."
