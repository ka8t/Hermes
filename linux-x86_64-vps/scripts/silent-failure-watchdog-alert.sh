#!/usr/bin/env bash
# Issue #85's immediate `wall` alert — triggered via OnFailure= in
# silent-failure-watchdog.service (see silent-failure-watchdog-alert.service.example),
# never run directly. Broadcasts to every logged-in SSH session the
# moment the watchdog fails, complementing 95-hermes-watchdog-status's
# persistent login-banner warning (which only a NEW login would see).
#
# Only fires on the actual transition into failure — reads the state
# file silent-failure-watchdog.sh itself just wrote and checks
# first_failed_at is fresh (this same check cycle), not just "currently
# failed" — systemd's OnFailure= would otherwise re-trigger this on
# every subsequent failed 5-minute re-check too, meaning a fresh `wall`
# interrupting every terminal on the box every 5 minutes for the whole
# outage instead of once at the start of it.
set -euo pipefail

STATE_FILE="/root/.hermes/silent-failure-watchdog.state.json"
[ -f "${STATE_FILE}" ] || exit 0

# Prints the reason if this run represents a fresh transition into
# failure (first_failed_at within the last 6 minutes — one watchdog
# check cycle plus margin), nothing otherwise.
REASON="$(python3 - "${STATE_FILE}" <<'PYEOF'
import json, sys, time

try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
except Exception:
    sys.exit(0)

if s.get("status") != "failed":
    sys.exit(0)

first_failed_at = s.get("first_failed_at") or 0
if time.time() - first_failed_at >= 360:
    sys.exit(0)  # already alerted for this outage

print(s.get("reason") or "unknown reason")
PYEOF
)"

[ -z "${REASON}" ] && exit 0

wall "Hermes silent-failure-watchdog just failed: ${REASON} -- it cannot currently alert Telegram users about silent hermes replies (issue #85). See: sudo journalctl -u silent-failure-watchdog.service -n 20"
