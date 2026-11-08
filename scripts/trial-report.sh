#!/bin/sh
# Prints the 2-week trial pass criteria from the backend.
#   API_URL=https://... MAC_TOKEN=... ./scripts/trial-report.sh [days]
API_URL=${API_URL:-http://localhost:8787}
: "${MAC_TOKEN:?set MAC_TOKEN}"
curl -s -H "Authorization: Bearer $MAC_TOKEN" "$API_URL/v1/stats?days=${1:-14}" | python3 -c "
import json, sys
s = json.load(sys.stdin)
days = s['opens_per_day']
avg = sum(days.values()) / max(1, s['days'])
ok = lambda b: 'PASS' if b else 'not yet'
print('Trial report, last %d days' % s['days'])
print('  Panel opens:   %.1f a day on average (pass: 10+)   %s' % (avg, ok(avg >= 10)))
for d in sorted(days): print('    %s  %d' % (d, days[d]))
print('  Agent items: %d, acted on within 48h: %d (%d%%) (pass: 70%%+)   %s' % (s['agent_items'], s['agent_items_acted_within_48h'], s['pct_acted'], ok(s['pct_acted'] >= 70)))
print('  Workflowy closed all 14 days, and the day 7 / day 14 gut check: your call.')
"
