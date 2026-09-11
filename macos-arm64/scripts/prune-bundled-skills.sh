#!/usr/bin/env bash
# Prunes bundled upstream skills irrelevant to this deployment's actual
# scope (issue #99) — the system prompt's <available_skills> index lists
# every skill nousresearch/hermes-agent bundles by default (58 total, this
# repo added only 3: clarify-agent-intent, build-agent-from-intent,
# verify-before-success), most with zero relevance to "monitor sources,
# report on a schedule, via Telegram/email". Real cost, not cosmetic:
# roughly half the system prompt's ~15.6KB is this index alone (measured
# live, 2026-09-10, from a request-debug dump), and more options is more
# surface area for a wrong-skill pick (the exact class of bug #76's
# SOUL.md instruction already had to patch).
#
# Uses hermes-agent's own supported mechanism (tools/skill_usage.py's
# archive_skill()) rather than deleting anything: moves a skill's
# directory to .archive/ and records it in .curator_suppressed so sync
# won't restore it (skills_sync.py's own documented behavior:
# "user-DELETED skills are not re-added"). Reversible with restore_skill()
# -- see the "undo" note at the end of this script's output. Gated on
# curator.prune_builtins (default true, hermes_cli/config_defaults.py) --
# already satisfied on a stock deployment; a skill marked
# is_protected_builtin refuses pruning automatically (archive_skill
# reports why instead of erroring), so this can't remove load-bearing UX.
#
# KEEP list (not pruned) and why: hermes-agent (self-config/troubleshoot,
# instructed to load before any Hermes admin task), the 3 skills this
# repo added, email-inbox-triage + himalaya (the email channel this repo
# just added, #89), arxiv + competitor-news-monitor + grounded-citations +
# llm-wiki (research category -- directly matches "AI news" monitoring),
# youtube-content (content-watcher template's own suggested source),
# blocked-page-recovery (generically useful for any web-based
# monitoring). Everything else bundled is pruned: autonomous-ai-agents
# (coding-agent delegation), creative, remaining media, note-taking, most
# of productivity, social-media, software-development.
#
# HERMES_MODE: "docker" (default) or "native" — same convention as
# eval/lib-hermes-env.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HERMES_MODE="${HERMES_MODE:-docker}"
HERMES_CONTAINER="${HERMES_CONTAINER:-hermes}"

PRUNE_LIST=(
  # autonomous-ai-agents (coding-agent delegation, not this deployment's job)
  claude-code codex computer-use opencode
  # creative (design/art tools)
  architecture-diagram ascii-video baoyu-infographic claude-design
  design-md humanizer manim-video p5js popular-web-designs
  songwriting-and-ai-music
  # media (keep youtube-content — matches content-watcher's own sources)
  gif-search songsee
  # note-taking
  obsidian
  # productivity (office/document tooling, unrelated to monitoring+reporting)
  airtable box document-to-action-items docx google-workspace maps
  meeting-action-items notion pdf powerpoint product-price-monitor
  teams-meeting-pipeline weekly-review-planning xlsx
  # social-media
  xurl
  # software-development (this is a monitoring/reporting agent, not a coding one)
  codebase-inspection dogfood github hermes-agent-skill-authoring
  inspecting-hermes-desktop-dom node-inspect-debugger python-debugpy
  requesting-code-review simplify-code spike systematic-debugging
  test-driven-development
)

PY='
import sys
sys.path.insert(0, "/opt/hermes")
from tools.skill_usage import archive_skill
name = sys.argv[1]
ok, msg = archive_skill(name)
print(("PRUNED" if ok else "SKIPPED") + f": {name} — {msg}")
'

echo "==> Pruning ${#PRUNE_LIST[@]} bundled skills irrelevant to this deployment (issue #99)"
PRUNED_COUNT=0
SKIPPED_COUNT=0
for name in "${PRUNE_LIST[@]}"; do
  case "${HERMES_MODE}" in
    docker)
      RESULT="$(docker exec "${HERMES_CONTAINER}" python3 -c "${PY}" "${name}" 2>/dev/null || true)"
      ;;
    native)
      RESULT="$(python3 -c "${PY}" "${name}" 2>/dev/null || true)"
      ;;
    *)
      echo "Unknown \$HERMES_MODE '${HERMES_MODE}' — expected 'docker' or 'native'." >&2
      exit 2
      ;;
  esac
  echo "${RESULT}"
  case "${RESULT}" in
    PRUNED:*) PRUNED_COUNT=$((PRUNED_COUNT + 1)) ;;
    *) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
  esac
done

echo ""
echo "==> Done: ${PRUNED_COUNT} pruned, ${SKIPPED_COUNT} skipped (already pruned, protected, or not found)."
echo "    To undo one: restore_skill('<name>') via the same python3 -c pattern, or"
echo "    hermes skills config (interactive) shows current state either way."
