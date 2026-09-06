#!/usr/bin/env bash
# Guided first-use demo (issue #63, part of #59) — the actual point of the
# guided setup flow: not just "the container is up," but a real, understood
# first success using this repo's own flagship feature (natural-language
# agent creation via the bundled clarify-agent-intent/build-agent-from-intent
# skills). Called from provision.sh's interactive flow; also runnable
# standalone once a deployment is already up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEMO_PROMPT="Create an agent that watches a subreddit for AI news and messages me when something important comes up"

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

case "${CHANNEL_CHOICE}" in
  2)
    echo "==> Sending: \"${DEMO_PROMPT}\""
    echo "    (this blocks until the reply is ready — that's expected, not stuck)"
    echo ""
    docker compose exec hermes hermes -z "${DEMO_PROMPT}"
    ;;
  *)
    echo "==> Send your Telegram bot this exact message now:"
    echo ""
    echo "    ${DEMO_PROMPT}"
    echo ""
    echo "==> Waiting for the reply (checking every 30s, up to 45 minutes)..."
    START_TS="$(date +%s)"
    FOUND=""
    for _ in $(seq 1 90); do
      REPLY="$(docker compose exec -T hermes python3 -c "
import sqlite3, sys
con = sqlite3.connect('/opt/data/state.db')
cur = con.cursor()
cur.execute('''
    SELECT content FROM messages
    WHERE role='assistant' AND content IS NOT NULL AND content != ''
      AND timestamp > ?
    ORDER BY id DESC LIMIT 1
''', (float(sys.argv[1]),))
row = cur.fetchone()
print(row[0] if row else '')
" "${START_TS}" 2>/dev/null || true)"
      if [ -n "${REPLY}" ]; then
        echo ""
        echo "==> Reply received:"
        echo ""
        echo "${REPLY}"
        FOUND=1
        break
      fi
      sleep 30
    done
    if [ -z "${FOUND}" ]; then
      echo ""
      echo "!! No reply yet after 45 minutes — that's longer than the documented"
      echo "!! worst case. Check: docker compose logs --since 45m hermes | grep -i telegram"
      echo "!! and see ../shared/telegram-setup.md's troubleshooting section."
    fi
    ;;
esac

echo ""
echo "==> That's the core loop: describe what you want, Hermes builds it via"
echo "    its bundled skills. From here:"
echo "    - Ask it anything else the same way (Telegram or terminal both work)"
echo "    - Check what it scheduled: docker compose exec hermes hermes cron list"
echo "    - Go deeper: docs/GLOSSARY.md, ../shared/managing-models.md"
