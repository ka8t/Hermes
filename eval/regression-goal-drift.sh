#!/usr/bin/env bash
# Regression gate for issue #37 (agentic goal-drift): runs the exact
# regression prompt from #37's root-cause investigation against a running
# Hermes install and checks whether the model's FIRST tool call is the
# correct project-specific skill or the known wrong generic tool
# (delegate_task). See shared/model-notes.md's #37 section for the full
# root-cause writeup and why this is the durable fix #37 calls for (a
# permanent pass/fail gate, not a claim that the model itself behaves
# differently — already established as not achievable via prompt/skill
# engineering alone).
#
# Runs against either a Docker container or a native install — see
# eval/lib-hermes-env.sh for $HERMES_MODE and the other env vars this
# reads (this is the "pseudo-prod" parametrization: the same script runs
# unchanged for the Mac-native leg and the VPS/Docker leg). Needs a
# healthy llama-swap behind it either way — this issues a real oneshot
# `hermes -z` call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-hermes-env.sh
source "${SCRIPT_DIR}/lib-hermes-env.sh"

PROMPT="Create an agent that watches a subreddit for AI news and messages me when something important comes up"
# Tool/skill names that correctly handle this request — anything else
# (most notably delegate_task, #37's documented wrong pick) is a FAIL.
CORRECT_TOOLS=("clarify" "skill_view" "skill_manage")

hermes_env_check

echo "==> [${HERMES_MODE}] Launching oneshot: hermes -z \"${PROMPT}\""
hermes_launch_oneshot "${PROMPT}"

SESSION_ID=""
TOOL_NAME=""
# No `timeout` on macOS by default — poll with an iteration cap instead.
# 200 * 3s = 10 min: generous enough that a genuinely slow turn (cold
# skill-loading, a long first response) doesn't get misread as "no tool
# call" — the original 40-iteration (2 min) window was too short, timing
# out a real run before its outcome could be observed either way (found
# live 2026-09-04).
for _ in $(seq 1 200); do
  if [ -z "${SESSION_ID}" ]; then
    SESSION_ID="$(hermes_query_db "
con = sqlite3.connect(DB_PATH)
cur = con.cursor()
cur.execute(\"SELECT id FROM sessions WHERE source='cli' ORDER BY started_at DESC LIMIT 1\")
row = cur.fetchone()
print(row[0] if row else '')
")"
  fi

  if [ -n "${SESSION_ID}" ]; then
    TOOL_NAME="$(hermes_query_db "
import json
con = sqlite3.connect(DB_PATH)
cur = con.cursor()
cur.execute(\"SELECT tool_calls FROM messages WHERE session_id=? AND tool_calls IS NOT NULL ORDER BY id ASC LIMIT 1\", ('${SESSION_ID}',))
row = cur.fetchone()
if row:
    calls = json.loads(row[0])
    print(calls[0]['function']['name'])
")"
  fi

  if [ -n "${TOOL_NAME}" ]; then
    break
  fi
  sleep 3
done

hermes_kill_oneshot

if [ -z "${TOOL_NAME}" ]; then
  echo "FAIL: no tool call observed within the polling window — check /tmp/regression-oneshot.log (session: ${SESSION_ID:-none found})." >&2
  exit 1
fi

echo "First tool call: ${TOOL_NAME}"
for ok in "${CORRECT_TOOLS[@]}"; do
  if [ "${TOOL_NAME}" = "${ok}" ]; then
    echo "PASS: model correctly used a skill-related tool (${TOOL_NAME}) instead of delegate_task."
    exit 0
  fi
done

echo "FAIL: model called '${TOOL_NAME}' instead of a skill-related tool — this is #37's documented goal-drift failure."
exit 1
