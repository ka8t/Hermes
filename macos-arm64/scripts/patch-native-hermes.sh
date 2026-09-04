#!/usr/bin/env bash
# Applies to a native Hermes install the same two fixes the Docker image
# (ghcr.io/ka8t/hermes, see ../../docker/Dockerfile) bakes in at build
# time — the official installer has no equivalent step, so a native
# install silently misses both unless this runs. Idempotent: each patch
# checks its own current state before touching anything.
#
# Run after ./install-hermes-native.sh + ./setup-hermes-native.sh, and
# again after any `hermes update` (an update re-clones/rebuilds the
# venv, which would silently drop the web_tools.py patch — SOUL.md is
# untouched by updates since it lives in $HERMES_HOME, not the install
# tree, but re-running this is harmless either way).
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WEB_TOOLS="${HERMES_HOME}/hermes-agent/tools/web_tools.py"
SOUL_MD="${HERMES_HOME}/SOUL.md"

# --- #50: web_search tool-name collision with llama-server ---
# See ../../docker/patch-web-search-schema.py and
# ../../shared/model-notes.md's #50 section for the full root cause.
if [ ! -f "${WEB_TOOLS}" ]; then
  echo "!! ${WEB_TOOLS} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${WEB_TOOLS}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

old = '''            "query": {
                "type": "string",
                "description": "The search query to look up on the web. You may include backend-supported operators such as site:example.com, filetype:pdf, intitle:word, -term, or \\"exact phrase\\"."
            },
            "limit": {
                "type": "integer",
                "description": "Maximum number of results to return. Defaults to 5.",
                "minimum": 1,
                "maximum": 100,
                "default": 5
            }
        },
        "required": ["query"]'''

new = '''            "query": {
                "type": "string",
                "description": "The search query to look up on the web. You may include backend-supported operators such as site:example.com, filetype:pdf, intitle:word, -term, or \\"exact phrase\\"."
            }
        },
        "required": ["query"]'''

if new in text:
    print("==> web_search schema already patched (#50) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> web_search schema patched (#50)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "shared/model-notes.md's #50 section and update this script."
    )
PY

# --- #48: mandatory verify-before-success instruction in SOUL.md ---
# See ../../docker/SOUL.md and ../../shared/model-notes.md's #48 section.
MARKER="Before sending any message that states or implies a task succeeded"
if [ ! -f "${SOUL_MD}" ]; then
  echo "!! ${SOUL_MD} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
if grep -qF "${MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the verify-before-success instruction (#48) — left as is"
else
  printf '\n\nBefore sending any message that states or implies a task succeeded, completed, or was created/saved/updated — list the tool calls that outcome depends on and check each one'"'"'s actual result field, not its intended purpose. If any of them returned an error or success:false, say so plainly and name what failed; never describe a failed tool call in the past tense as something that worked. A well-written, confident summary of a failed attempt is still a false report.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched (#48)"
fi
