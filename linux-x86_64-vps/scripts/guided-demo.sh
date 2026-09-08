#!/usr/bin/env bash
# Guided first-use demo (issue #63, part of #59) — the actual point of the
# guided setup flow: not just "the container is up," but a real, understood
# first success using this repo's own flagship feature (natural-language
# agent creation via the bundled clarify-agent-intent/build-agent-from-intent
# skills). Called from provision.sh's interactive flow; also runnable
# standalone once a deployment is already up.
#
# HERMES_RUN_MODE: "docker" (default) or "native" — set by provision.sh
# based on what the user chose there (mirrors macos-arm64/'s pattern, #76
# follow-up). Determines both how `hermes` is invoked and where state.db
# lives.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HERMES_RUN_MODE="${HERMES_RUN_MODE:-docker}"
DEMO_PROMPT="Create an agent that watches a subreddit for AI news and messages me when something important comes up"

if [ "${HERMES_RUN_MODE}" = "native" ]; then
  hermes_cmd() { hermes "$@"; }
else
  hermes_cmd() { docker compose exec -T hermes hermes "$@"; }
fi

echo ""
echo "==> Let's try it. Hermes builds things for you just by describing what"
echo "    you want in plain language — that's the actual point of this"
echo "    project, not just having a server running."
echo ""
echo "How do you want to try it?"
echo "  1) Telegram (send it from your phone)"
echo "  2) Terminal (right here, right now)"
read -r -p "Choice [1/2]: " CHANNEL_CHOICE

echo ""
echo "!! On this VPS's CPU-only hardware, the FIRST reply in a fresh session"
echo "!! can genuinely take 25-40+ minutes — that's normal, not a hang (the"
echo "!! model has to read a large system prompt before it can answer at"
echo "!! all). See ../shared/telegram-setup.md if you want the details."
echo ""

# Real-success check (issue #76 follow-up, 2026-09-07): a non-empty reply is
# not proof anything was actually built — live testing this same session
# found the model can reply with a fabricated "done" claim, or an internal
# marker leaking into the text, while never calling a tool at all. The demo
# prompt asks for a scheduled watcher, so a genuine success registers a new
# cron job — check that directly instead of trusting the reply text alone.
CRON_BEFORE="$(hermes_cmd cron list --all 2>/dev/null || true)"
report_result() {
  local reply="$1"
  local cron_after
  cron_after="$(hermes_cmd cron list --all 2>/dev/null || true)"
  echo ""
  echo "==> Reply received:"
  echo ""
  echo "${reply}"
  echo ""
  if [ "${cron_after}" != "${CRON_BEFORE}" ] && ! printf '%s' "${cron_after}" | grep -q "No scheduled jobs"; then
    echo "==> Confirmed: a new scheduled job showed up in 'hermes cron list' —"
    echo "    the agent was actually created, not just described."
  else
    echo "!! No new scheduled job showed up in 'hermes cron list' — the reply"
    echo "!! above may describe or explain the task instead of actually having"
    echo "!! built it. Worth checking yourself: docker compose exec hermes"
    echo "!! hermes cron list. See issues #75/#76 on github.com/ka8t/Hermes if"
    echo "!! this reproduces consistently."
  fi
}

case "${CHANNEL_CHOICE}" in
  2)
    echo "==> Sending: \"${DEMO_PROMPT}\""
    echo "    (this blocks until the reply is ready — that's expected, not stuck)"
    echo ""
    REPLY="$(hermes_cmd -z "${DEMO_PROMPT}")"
    report_result "${REPLY}"
    ;;
  *)
    echo "==> Send your Telegram bot this exact message now:"
    echo ""
    echo "    ${DEMO_PROMPT}"
    echo ""
    echo "==> Waiting for the reply (checking every 30s, up to 45 minutes)..."
    START_TS="$(date +%s)"
    FOUND=""
    STATE_DB_QUERY='
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
cur = con.cursor()
cur.execute("""
    SELECT content FROM messages
    WHERE role='"'"'assistant'"'"' AND content IS NOT NULL AND content != '"'"''"'"'
      AND timestamp > ?
    ORDER BY id DESC LIMIT 1
""", (float(sys.argv[2]),))
row = cur.fetchone()
print(row[0] if row else "")
'
    for _ in $(seq 1 90); do
      if [ "${HERMES_RUN_MODE}" = "native" ]; then
        REPLY="$(python3 -c "${STATE_DB_QUERY}" "$HOME/.hermes/state.db" "${START_TS}" 2>/dev/null || true)"
      else
        REPLY="$(docker compose exec -T hermes python3 -c "${STATE_DB_QUERY}" /opt/data/state.db "${START_TS}" 2>/dev/null || true)"
      fi
      if [ -n "${REPLY}" ]; then
        report_result "${REPLY}"
        FOUND=1
        break
      fi
      sleep 30
    done
    if [ -z "${FOUND}" ]; then
      echo ""
      echo "!! No reply yet after 45 minutes — that's longer than the documented"
      echo "!! worst case. Check: docker compose logs --since 45m hermes | grep -i telegram"
      echo "!! (or, native: hermes gateway status) and see"
      echo "!! ../shared/telegram-setup.md's troubleshooting section."
    fi
    ;;
esac

echo ""
echo "==> That's the core loop: describe what you want, Hermes builds it via"
echo "    its bundled skills. From here:"
echo "    - Ask it anything else the same way (Telegram or terminal both work)"
echo "    - Check what it scheduled: hermes cron list (or docker compose exec"
echo "      hermes hermes cron list)"
echo "    - Go deeper: docs/GLOSSARY.md, ../shared/managing-models.md"
