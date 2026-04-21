#!/usr/bin/env bash
# Team status dashboard — run any time to see current team + build state.
# No dependency on the broken SendMessage inbox; reads ground truth from disk.
set -uo pipefail

JOT=/Users/tejasdc/workspace/jot-mobile
TEAMS=~/.claude/teams/jot-mobile

section() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }

section "Status mirrors (newest first)"
if [[ -d "$JOT/tmp/status" ]]; then
  ls -lat "$JOT/tmp/status"/*.md 2>/dev/null | awk '{print $6, $7, $8, $9}'
else
  echo "(no tmp/status directory)"
fi

section "Source files modified in last 20 min"
find "$JOT/Jot" -type f -mmin -20 \
  ! -path '*/Jot.xcodeproj/*' ! -path '*/build/*' ! -path '*/DerivedData/*' 2>/dev/null

section "Latest 5 build logs"
if [[ -d "$JOT/build-logs" ]]; then
  ls -lat "$JOT/build-logs"/*.log 2>/dev/null | head -5 | awk '{print $6, $7, $8, $5, $9}'
else
  echo "(no build-logs directory)"
fi

section "Monitor poll process"
# shellcheck disable=SC2009
ps aux | grep -E "jot-inbox-poll" | grep -v grep || echo "(monitor NOT running — restart with Claude Monitor tool)"

section "Team members (active=True means currently producing output)"
python3 - <<'PY'
import json
try:
    d = json.load(open('/Users/tejasdc/.claude/teams/jot-mobile/config.json'))
    for m in d['members']:
        a = m.get('isActive', '?')
        print(f"  {m['name']:35s} active={a}")
except Exception as e:
    print(f"  (error reading team config: {e})")
PY

section "Inbox: latest 10 non-noise messages to team-lead"
python3 - <<'PY'
import json, os
inbox = os.path.expanduser('~/.claude/teams/jot-mobile/inboxes/team-lead.json')
try:
    msgs = json.load(open(inbox))
except Exception as e:
    print(f"  (error: {e})")
    raise SystemExit
non_noise = [m for m in msgs if not (
    isinstance(m.get('text',''), dict)
    or 'idle_notification' in str(m.get('text',''))
    or 'shutdown_approved' in str(m.get('text',''))
)]
print(f"  Total: {len(msgs)}, unread: {sum(1 for m in msgs if not m.get('read'))}, non-noise last 10:")
for m in non_noise[-10:]:
    t = m.get('timestamp','')[:19]
    who = m.get('from', '?')
    summary = (m.get('summary') or '(no summary)')[:70]
    print(f"    [{t}] {who:30s} {summary}")
PY

section "Unread-to-team-lead count per sender (pending that lead hasn't surfaced)"
python3 - <<'PY'
import json, os
from collections import Counter
inbox = os.path.expanduser('~/.claude/teams/jot-mobile/inboxes/team-lead.json')
try:
    msgs = json.load(open(inbox))
except Exception:
    raise SystemExit
unread_noise = Counter()
unread_sig = Counter()
for m in msgs:
    if m.get('read'):
        continue
    t = m.get('text', '')
    if isinstance(t, dict) or 'idle_notification' in str(t) or 'shutdown_approved' in str(t):
        unread_noise[m.get('from','?')] += 1
    else:
        unread_sig[m.get('from','?')] += 1
print("  Signal (actual messages):")
for k, v in sorted(unread_sig.items(), key=lambda x: -x[1]):
    print(f"    {k:30s} {v}")
print("  Noise (idle/shutdown — safely ignored):")
for k, v in sorted(unread_noise.items(), key=lambda x: -x[1]):
    print(f"    {k:30s} {v}")
PY

section "Done"
