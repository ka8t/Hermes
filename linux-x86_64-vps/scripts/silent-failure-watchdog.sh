#!/usr/bin/env bash
# Local stopgap for issue #56: hermes-agent's tool-calling loop can end a
# session with end_reason='agent_close' and zero assistant messages after a
# tool error — a real Telegram user gets no reply and no indication anything
# went wrong. This script cannot fix that upstream loop (not this repo's
# code); it detects the symptom in state.db and sends a fallback message
# directly via the Telegram Bot API, bypassing hermes-agent for that one
# corrective message. See the spec comment on #56 for the full design.
#
# Run periodically (every few minutes), not as a long-running daemon — see
# silent-failure-watchdog.timer.example for the systemd wiring.
#
# HERMES_MODE: "docker" (default) or "native" — same convention as
# eval/lib-hermes-env.sh. docker: reads state.db from the running "hermes"
# container via `docker exec`. native: reads $HERMES_HOME/state.db directly.
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

# Host-side marker file, independent of $HERMES_MODE (this script always
# runs on the host, never inside the container) — records the latest
# sessions.ended_at already processed, so a session is never notified twice.
MARKER_FILE="$HOME/.hermes/silent-failure-watchdog.last-checked"
mkdir -p "$(dirname "${MARKER_FILE}")"
LAST_CHECKED="$(cat "${MARKER_FILE}" 2>/dev/null || echo 0)"

FALLBACK_TEXT="Something went wrong processing your last message and no response was generated. Please try again or rephrase your request."

# shellcheck disable=SC2016
QUERY='
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
cur = con.cursor()
cur.execute("""
    SELECT s.id, s.chat_id, s.ended_at
    FROM sessions s
    WHERE s.source = '"'"'telegram'"'"'
      AND s.end_reason = '"'"'agent_close'"'"'
      AND s.chat_id IS NOT NULL
      AND s.ended_at > ?
      AND NOT EXISTS (
        SELECT 1 FROM messages m
        WHERE m.session_id = s.id
          AND m.role = '"'"'assistant'"'"'
          AND m.content IS NOT NULL
          AND m.content != '"'"''"'"'
      )
    ORDER BY s.ended_at ASC
""", (float(sys.argv[2]),))
max_ended = float(sys.argv[2])
for session_id, chat_id, ended_at in cur.fetchall():
    print(f"{session_id}\t{chat_id}\t{ended_at}")
    max_ended = max(max_ended, ended_at)
print(f"__MAX_ENDED__\t{max_ended}", file=sys.stderr)
'

# A fixed shared path here (e.g. plain /tmp/silent-failure-watchdog.stderr)
# broke on the VPS: one invocation (interactive, as an unprivileged user)
# created it, then systemd's own run (as root) couldn't reuse that same
# path — a real permission conflict, found live-testing the systemd timer.
# A fresh, uniquely-named file per invocation sidesteps that entirely and
# also makes concurrent runs safe.
STDERR_CAPTURE="$(mktemp)"
trap 'rm -f "${STDERR_CAPTURE}"' EXIT

case "${HERMES_MODE}" in
  docker)
    if ! docker exec "${HERMES_CONTAINER}" true 2>/dev/null; then
      echo "Docker container '${HERMES_CONTAINER}' not reachable — set \$HERMES_CONTAINER or start it." >&2
      exit 2
    fi
    RESULT="$(docker exec "${HERMES_CONTAINER}" python3 -c "${QUERY}" /opt/data/state.db "${LAST_CHECKED}" 2>"${STDERR_CAPTURE}")"
    ;;
  native)
    if [ ! -f "${HERMES_HOME}/state.db" ]; then
      echo "${HERMES_HOME}/state.db not found — has the gateway ever run? (\$HERMES_HOME=${HERMES_HOME})" >&2
      exit 2
    fi
    RESULT="$(python3 -c "${QUERY}" "${HERMES_HOME}/state.db" "${LAST_CHECKED}" 2>"${STDERR_CAPTURE}")"
    ;;
  *)
    echo "Unknown \$HERMES_MODE '${HERMES_MODE}' — expected 'docker' or 'native'." >&2
    exit 2
    ;;
esac

NEW_MAX="$(grep "^__MAX_ENDED__" "${STDERR_CAPTURE}" | cut -f2)"
[ -n "${NEW_MAX}" ] && echo "${NEW_MAX}" > "${MARKER_FILE}"

TELEGRAM_BOT_TOKEN="$(grep "^TELEGRAM_BOT_TOKEN=" "${PLATFORM_DIR}/.env" 2>/dev/null | cut -d= -f2-)"
if [ -z "${TELEGRAM_BOT_TOKEN}" ]; then
  echo "TELEGRAM_BOT_TOKEN not found in ${PLATFORM_DIR}/.env — cannot send fallback messages." >&2
  exit 2
fi

echo "${RESULT}" | while IFS=$'\t' read -r session_id chat_id ended_at; do
  [ -z "${session_id}" ] && continue
  echo "[silent-failure-watchdog] session ${session_id} ended silently (chat_id=${chat_id}) — sending fallback message"
  curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${FALLBACK_TEXT}" \
    >/dev/null || echo "[silent-failure-watchdog] failed to notify chat_id=${chat_id}" >&2
done
