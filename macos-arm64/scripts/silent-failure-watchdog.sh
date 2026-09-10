#!/usr/bin/env bash
# Local stopgap for issue #56: hermes-agent's tool-calling loop can leave a
# user's message with no reply at all after a tool error — a real Telegram
# user gets silence with no indication anything went wrong. This script
# cannot fix that upstream loop (not this repo's code); it detects the
# symptom in state.db and sends a fallback message directly via the
# Telegram Bot API, bypassing hermes-agent for that one corrective message.
# See the spec comments on #56 for the full design and its correction.
#
# Detection (corrected 2026-09-06 after live VPS testing found the original
# end_reason='agent_close' signature never occurs for real Telegram
# sessions — they stay open across many turns, unlike a CLI oneshot):
# for each Telegram session, look at the most recent 'user' message; if no
# non-empty 'assistant' message exists after it, AND enough time has passed
# that this can no longer be legitimate slow inference, it's silent.
#
# "Enough time" is derived from this deployment's own
# agent.local_stream_stale_timeout (config.yaml) — the same number Hermes
# itself uses as its stream-stale cutoff for a local endpoint — times 3, to
# cover hermes-agent's own retry budget (see shared/telegram-setup.md's
# "25-40+ minutes" section: up to 3 retries can legitimately happen before
# Hermes gives up). Was times 2 until 2026-09-10 -- confirmed live that a
# single stuck attempt can legitimately consume the FULL timeout (not just
# "some of it"), so a 2x margin could fire a false "something went wrong"
# while hermes was still honestly in its 3rd attempt. See
# shared/hardware-sizing.md's 2026-09-10 incident, and the --predict cap
# added to config/models.yaml.example the same day, which bounds how long
# a single stuck attempt can now run in the first place. Falls back to
# hermes-agent's own default local-endpoint ceiling (900s) if the setting
# isn't present in config.yaml.
#
# Run periodically (every few minutes), not as a long-running daemon — see
# com.hermes.silent-failure-watchdog.plist.example for the launchd wiring.
#
# HERMES_MODE: "docker" (default) or "native" — same convention as
# eval/lib-hermes-env.sh. docker: reads state.db/config.yaml from the
# running "hermes" container via `docker exec`. native: reads
# $HERMES_HOME/{state.db,config.yaml} directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(dirname "${SCRIPT_DIR}")"

# systemd (Type=oneshot, no User=) runs services with $HOME unset — unlike
# an interactive shell, it doesn't source a profile. Found live-testing this
# on the VPS: the script crashed on `set -u` before ever querying state.db.
# Resolve it ourselves so the script works the same whether invoked
# interactively, via launchd, or via a bare systemd unit.
: "${HOME:=$(eval echo "~$(id -un)")}"

HERMES_MODE="${HERMES_MODE:-docker}"
HERMES_CONTAINER="${HERMES_CONTAINER:-hermes}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# hermes-agent's own default stream-stale ceiling for a local endpoint (see
# shared/telegram-setup.md) — used when config.yaml doesn't override it.
DEFAULT_STALE_TIMEOUT_S=900
STALE_MARGIN_MULTIPLIER=3

# Host-side file of already-notified message IDs, independent of
# $HERMES_MODE (this script always runs on the host, never inside the
# container) — one id per line, so the same dangling user message is never
# notified twice. Small and self-trimming isn't implemented for v1 (real
# volume here is a handful of entries at most).
NOTIFIED_FILE="$HOME/.hermes/silent-failure-watchdog.notified-ids"
mkdir -p "$(dirname "${NOTIFIED_FILE}")"
touch "${NOTIFIED_FILE}"

FALLBACK_TEXT="Something went wrong processing your last message and no response was generated. Please try again or rephrase your request."

# A fixed shared path here (e.g. plain /tmp/silent-failure-watchdog.stderr)
# broke on the VPS: one invocation (interactive, as an unprivileged user)
# created it, then systemd's own run (as root) couldn't reuse that same
# path — a real permission conflict, found live-testing the systemd timer.
# A fresh, uniquely-named file per invocation sidesteps that entirely and
# also makes concurrent runs safe.
STDERR_CAPTURE="$(mktemp)"

# Issue #85: this watchdog is the ONLY thing standing between a silent
# hermes failure and the affected Telegram user finding out — but it can
# itself fail silently (found live on the VPS, 2026-09-10: a blank
# TELEGRAM_BOT_TOKEN during a legitimate token-rotation window made the
# VPS's copy of this script exit 2 on every run for ~35 minutes, visible
# only in the local systemd journal, nobody watching). Track every run's
# outcome in a state file, and on macOS fire a Notification Center alert
# directly on every failed run — the local, physically-present equivalent
# of the VPS's `wall` + login-banner combo (see
# silent-failure-watchdog-alert.service.example on the VPS side).
# Notification Center groups repeated alerts from the same source rather
# than flooding the screen, so unlike `wall` this doesn't need its own
# transition-only dedup logic — every 5-minute re-check re-notifying
# while still broken is fine here. LAST_ERROR_MSG is set right before
# each known failure's `exit`; the trap below also catches any
# *unforeseen* crash (a python traceback, a future bug) the same way, so
# this isn't limited to the failure modes anticipated today.
STATE_FILE="$HOME/.hermes/silent-failure-watchdog.state.json"
mkdir -p "$(dirname "${STATE_FILE}")"
LAST_ERROR_MSG=""

# shellcheck disable=SC2016
WRITE_STATE_PY='
import json, sys, time

state_file, status, reason = sys.argv[1], sys.argv[2], sys.argv[3]
now = time.time()

# Preserve the original failure time across consecutive failed runs, so
# the alert can say "failing since X" instead of just "failing now" —
# the duration is what tells you whether this is a brief, self-healing
# blip (e.g. a token rotation in progress) or something that needs
# attention.
prev_first_failed_at = None
try:
    with open(state_file) as f:
        prev = json.load(f)
    if prev.get("status") == "failed":
        prev_first_failed_at = prev.get("first_failed_at")
except Exception:
    pass

data = {"status": status, "reason": reason, "last_checked_at": now}
if status == "failed":
    data["first_failed_at"] = prev_first_failed_at or now
with open(state_file, "w") as f:
    json.dump(data, f)
'

# Passed as argv (sys.argv[2]/[3]), not interpolated into the Python
# source — the reason text can contain quotes/apostrophes (real error
# text does, e.g. "container 'hermes' not reachable") that would break a
# naive embed into an inline -c string.
write_state() {
  python3 -c "${WRITE_STATE_PY}" "${STATE_FILE}" "$1" "$2" 2>/dev/null || true
  if [ "$1" = "failed" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$2\" with title \"Hermes silent-failure-watchdog failed (issue #85)\" subtitle \"It can no longer alert you about silent hermes replies\"" >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local code=$?
  rm -f "${STDERR_CAPTURE}"
  if [ "${code}" -eq 0 ]; then
    write_state "ok" ""
  else
    write_state "failed" "${LAST_ERROR_MSG:-script exited with code ${code}}"
  fi
}
trap on_exit EXIT

on_exit() {
  local code=$?
  rm -f "${STDERR_CAPTURE}"
  if [ "${code}" -eq 0 ]; then
    write_state "ok" ""
  else
    write_state "failed" "${LAST_ERROR_MSG:-script exited with code ${code}}"
  fi
}
trap on_exit EXIT

# shellcheck disable=SC2016
QUERY='
import re, sqlite3, sys, time

db_path, config_text = sys.argv[1], sys.argv[2]

m = re.search(r"local_stream_stale_timeout:\s*(\d+)", config_text)
base_timeout = int(m.group(1)) if m else '"${DEFAULT_STALE_TIMEOUT_S}"'
threshold = base_timeout * '"${STALE_MARGIN_MULTIPLIER}"'
print(f"__THRESHOLD__\t{threshold}", file=sys.stderr)

con = sqlite3.connect(db_path)
cur = con.cursor()
cur.execute("""
    SELECT s.id, s.chat_id, um.id, um.timestamp
    FROM sessions s
    JOIN messages um ON um.id = (
        SELECT MAX(id) FROM messages
        WHERE session_id = s.id AND role = '"'"'user'"'"'
    )
    WHERE s.source = '"'"'telegram'"'"'
      AND s.chat_id IS NOT NULL
""")
now = time.time()
for session_id, chat_id, user_msg_id, ts in cur.fetchall():
    if now - ts <= threshold:
        continue
    cur2 = con.cursor()
    cur2.execute("""
        SELECT 1 FROM messages
        WHERE session_id = ? AND id > ? AND role = '"'"'assistant'"'"'
          AND content IS NOT NULL AND content != '"'"''"'"'
        LIMIT 1
    """, (session_id, user_msg_id))
    if cur2.fetchone() is None:
        print(f"{session_id}\t{chat_id}\t{user_msg_id}")
'

case "${HERMES_MODE}" in
  docker)
    if ! docker exec "${HERMES_CONTAINER}" true 2>/dev/null; then
      LAST_ERROR_MSG="Docker container '${HERMES_CONTAINER}' not reachable"
      echo "${LAST_ERROR_MSG} — set \$HERMES_CONTAINER or start it." >&2
      exit 2
    fi
    CONFIG_TEXT="$(docker exec "${HERMES_CONTAINER}" cat /opt/data/config.yaml 2>/dev/null || true)"
    RESULT="$(docker exec "${HERMES_CONTAINER}" python3 -c "${QUERY}" /opt/data/state.db "${CONFIG_TEXT}" 2>"${STDERR_CAPTURE}")"
    ;;
  native)
    if [ ! -f "${HERMES_HOME}/state.db" ]; then
      LAST_ERROR_MSG="${HERMES_HOME}/state.db not found"
      echo "${LAST_ERROR_MSG} — has the gateway ever run? (\$HERMES_HOME=${HERMES_HOME})" >&2
      exit 2
    fi
    CONFIG_TEXT="$(cat "${HERMES_HOME}/config.yaml" 2>/dev/null || true)"
    RESULT="$(python3 -c "${QUERY}" "${HERMES_HOME}/state.db" "${CONFIG_TEXT}" 2>"${STDERR_CAPTURE}")"
    ;;
  *)
    LAST_ERROR_MSG="Unknown \$HERMES_MODE '${HERMES_MODE}'"
    echo "${LAST_ERROR_MSG} — expected 'docker' or 'native'." >&2
    exit 2
    ;;
esac

TELEGRAM_BOT_TOKEN="$(grep "^TELEGRAM_BOT_TOKEN=" "${PLATFORM_DIR}/.env" 2>/dev/null | cut -d= -f2-)"
if [ -z "${TELEGRAM_BOT_TOKEN}" ]; then
  LAST_ERROR_MSG="TELEGRAM_BOT_TOKEN not found in ${PLATFORM_DIR}/.env"
  echo "${LAST_ERROR_MSG} — cannot send fallback messages." >&2
  exit 2
fi

echo "${RESULT}" | while IFS=$'\t' read -r session_id chat_id user_msg_id; do
  [ -z "${session_id}" ] && continue
  if grep -qxF "${user_msg_id}" "${NOTIFIED_FILE}"; then
    continue
  fi
  echo "[silent-failure-watchdog] session ${session_id} message ${user_msg_id} silent (chat_id=${chat_id}) — sending fallback message"
  if curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${FALLBACK_TEXT}" \
    >/dev/null; then
    echo "${user_msg_id}" >> "${NOTIFIED_FILE}"
  else
    echo "[silent-failure-watchdog] failed to notify chat_id=${chat_id}" >&2
  fi
done
