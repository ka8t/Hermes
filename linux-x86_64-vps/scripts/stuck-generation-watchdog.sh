#!/usr/bin/env bash
# Alert-only stopgap for issue #86: llama.cpp/llama-swap don't cancel a
# generation when hermes's own client disconnects (see
# shared/hardware-sizing.md's 2026-09-10 incident, and #82's writeup on
# the same finding). #82's `--predict 4096` cap bounds how long any single
# completion SHOULD take, but a genuinely stuck request can still occupy
# llama-server's single slot for that whole window, and a retry queuing
# behind it repeats the wait — reproduced live twice in one morning,
# 2026-09-10.
#
# This script detects "llama-server has been running continuously longer
# than a generation should ever legitimately take, with zero completed
# requests logged in that whole window" and sends a Telegram alert to
# TELEGRAM_HOME_CHANNEL. It deliberately does NOT restart anything —
# auto-restart was considered and explicitly rejected for v1 (2026-09-10
# decision, see #86): a long-running request might still be a
# legitimately slow one this script can't reliably tell apart from a real
# hang, so a human decides whether to run `docker compose restart
# llama-swap`.
#
# Run periodically (every few minutes), not as a long-running daemon —
# see stuck-generation-watchdog.timer.example for the systemd wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${PLATFORM_DIR}"

# systemd (Type=oneshot, no User=) runs services with $HOME unset — see
# silent-failure-watchdog.sh's own comment on this same fix.
: "${HOME:=$(eval echo "~$(id -un)")}"

LLAMA_SWAP_CONTAINER="${LLAMA_SWAP_CONTAINER:-llama-swap}"

# Generous upper bound on how long a single completion should ever
# legitimately take on this deployment: worst documented prefill (~13 min
# for a ~17,488-token prompt at this VPS's measured 22.3 tok/s prefill,
# shared/hardware-sizing.md) plus the --predict 4096 generation cap's
# worst case (~9 min at 7.4 tok/s generation) ~= 22 min, rounded up with
# margin. Override with $STUCK_THRESHOLD_S if this deployment's own
# verify-inference.sh numbers differ meaningfully from the reference VPS.
STUCK_THRESHOLD_S="${STUCK_THRESHOLD_S:-1800}"

# One alert per stuck PID per day — a still-stuck process keeps the same
# PID, so this also naturally re-alerts once a day if nobody's acted on
# it, without spamming every 5-minute run in between.
NOTIFIED_FILE="$HOME/.hermes/stuck-generation-watchdog.notified-pids"
mkdir -p "$(dirname "${NOTIFIED_FILE}")"
touch "${NOTIFIED_FILE}"

if ! docker exec "${LLAMA_SWAP_CONTAINER}" true 2>/dev/null; then
  echo "Docker container '${LLAMA_SWAP_CONTAINER}' not reachable — nothing to check." >&2
  exit 0
fi

# One line per llama-server process: "<pid> <etimes>"
PROCS="$(docker exec "${LLAMA_SWAP_CONTAINER}" ps -o pid,etimes --no-headers -C llama-server 2>/dev/null || true)"

# No model currently loaded — nothing to check, not an error.
[ -z "${PROCS}" ] && exit 0

TELEGRAM_BOT_TOKEN="$(grep "^TELEGRAM_BOT_TOKEN=" "${PLATFORM_DIR}/.env" 2>/dev/null | cut -d= -f2-)"
TELEGRAM_HOME_CHANNEL="$(grep "^TELEGRAM_HOME_CHANNEL=" "${PLATFORM_DIR}/.env" 2>/dev/null | cut -d= -f2-)"

echo "${PROCS}" | while read -r pid etimes; do
  [ -z "${pid}" ] && continue
  [ "${etimes}" -lt "${STUCK_THRESHOLD_S}" ] && continue

  # A completed request in the same window means llama-server is busy
  # (possibly with a NEW request that just started right as an old one
  # ended), not necessarily stuck — only alert when nothing has finished
  # in the whole threshold window.
  RECENT_COMPLETIONS="$(docker compose logs "${LLAMA_SWAP_CONTAINER}" \
    --since "${STUCK_THRESHOLD_S}s" 2>/dev/null | grep -c 'POST /v1/chat/completions' || true)"
  [ "${RECENT_COMPLETIONS:-0}" -gt 0 ] && continue

  NOTIFY_KEY="${pid}-$(date +%Y%m%d)"
  if grep -qxF "${NOTIFY_KEY}" "${NOTIFIED_FILE}"; then
    continue
  fi

  MINUTES=$((etimes / 60))
  echo "[stuck-generation-watchdog] llama-server pid ${pid} has been running ${etimes}s (~${MINUTES} min) with no completed request in the same window"

  if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_HOME_CHANNEL}" ]; then
    echo "[stuck-generation-watchdog] TELEGRAM_BOT_TOKEN or TELEGRAM_HOME_CHANNEL not set in .env — cannot send an alert (see issue #85 for this gap's own tracking)." >&2
    continue
  fi

  ALERT_TEXT="Hermes' local model (llama-server pid ${pid}) has been running continuously for ~${MINUTES} min with no completed reply -- this may be a stuck generation (see ka8t/Hermes issue #86). Not restarted automatically. Check with: docker compose exec llama-swap ps aux -- if genuinely stuck: docker compose restart llama-swap"

  if curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_HOME_CHANNEL}" \
    --data-urlencode "text=${ALERT_TEXT}" \
    >/dev/null; then
    echo "${NOTIFY_KEY}" >> "${NOTIFIED_FILE}"
  else
    echo "[stuck-generation-watchdog] failed to send Telegram alert" >&2
  fi
done
