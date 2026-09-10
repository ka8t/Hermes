#!/usr/bin/env bash
# Applies to a native Hermes install the same fixes the Docker image
# (ghcr.io/ka8t/hermes, see ../../docker/Dockerfile) bakes in at build
# time — the official installer has no equivalent step, so a native
# install silently misses all of them unless this runs. Idempotent: each
# patch checks its own current state before touching anything.
#
# Run after ./install-hermes-native.sh + ./setup-hermes-native.sh, and
# again after any `hermes update` (an update re-clones/rebuilds the
# venv, which would silently drop the web_tools.py/gateway.py/
# clarify_tool.py patches — SOUL.md is untouched by updates since it
# lives in $HERMES_HOME, not the install tree, but re-running this is
# harmless either way).
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_ROOT="${HERMES_HOME}/hermes-agent"
WEB_TOOLS="${INSTALL_ROOT}/tools/web_tools.py"
GATEWAY_PY="${INSTALL_ROOT}/hermes_cli/gateway.py"
CLARIFY_TOOL="${INSTALL_ROOT}/tools/clarify_tool.py"
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

# --- Allowed-channels gateway setup menu ---
# See ../../docker/patch-gateway-setup-allowed-channels.py — same patch,
# same reasoning and same ALLOWED_KEYS policy (channels this repo
# actually documents end-to-end; see ../../shared/telegram-setup.md,
# ../../shared/email-setup.md), applied to the native install's own copy
# of gateway.py instead of the Docker image's. Anchored on the function
# boundary and the last bare "return platforms" inside it, not on
# internal formatting, for the same reason as the Docker patch: found
# live, 2026-09-10, that upstream reformats this function's body
# cosmetically between releases. Was Telegram-only (#83) until #90
# widened it to also allow email — this script upgrades an
# already-Telegram-only-patched install in place, not just a pristine
# one, so re-running it after a `git pull` picks up the widened policy
# without needing a fresh install.
if [ ! -f "${GATEWAY_PY}" ]; then
  echo "!! ${GATEWAY_PY} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${GATEWAY_PY}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

ALLOWED_KEYS = ("telegram", "email")
NEW_MARKER = "ka8t/Hermes: only these channels are implemented"

NEW_BLOCK = (
    "    # ka8t/Hermes: only these channels are implemented, tested, and\n"
    "    # documented for this deployment (see shared/telegram-setup.md,\n"
    "    # shared/email-setup.md) -- filter the setup menu down to them\n"
    "    # instead of offering channels that would silently go unsupported.\n"
    "    # See macos-arm64/scripts/patch-native-hermes.sh /\n"
    "    # docker/patch-gateway-setup-allowed-channels.py.\n"
    f"    _ALLOWED = {ALLOWED_KEYS!r}\n"
    '    return [p for p in platforms if p["key"] in _ALLOWED]'
)

if NEW_MARKER in text:
    print(f"==> gateway setup menu already filtered to {ALLOWED_KEYS} — left as is")
    sys.exit(0)

# Upgrade path: an earlier run of this script (#83) already replaced the
# original "return platforms" with the Telegram-only version -- that
# exact block, not the pristine upstream one, is what's in the file now.
OLD_BLOCK = (
    "    # ka8t/Hermes: only Telegram is implemented, tested, and documented\n"
    "    # for this deployment (see shared/telegram-setup.md) -- filter the\n"
    "    # setup menu down to it instead of offering channels that would\n"
    "    # silently go unsupported. See\n"
    "    # macos-arm64/scripts/patch-native-hermes.sh /\n"
    "    # docker/patch-gateway-setup-telegram-only.py.\n"
    '    return [p for p in platforms if p["key"] == "telegram"]'
)
if OLD_BLOCK in text:
    target.write_text(text.replace(OLD_BLOCK, NEW_BLOCK, 1))
    print(f"==> gateway setup menu upgraded from Telegram-only to {ALLOWED_KEYS}")
    sys.exit(0)

# Pristine, never patched by this script before.
FUNC_START = "def _all_platforms("
start = text.find(FUNC_START)
if start == -1:
    sys.exit(
        f"!! _all_platforms() not found in {target} — the installed "
        "hermes-agent version may have changed this file. Check "
        "../../docker/patch-gateway-setup-allowed-channels.py and update "
        "this script."
    )
end = text.find("\ndef ", start + len(FUNC_START))
if end == -1:
    end = len(text)
func_body = text[start:end]

RETURN_MARKER = "    return platforms"
last_idx = func_body.rfind(RETURN_MARKER)
if last_idx == -1:
    sys.exit(
        f"!! no 'return platforms' found inside _all_platforms() in {target} "
        "— the installed hermes-agent version may have changed this "
        "file. Check ../../docker/patch-gateway-setup-allowed-channels.py "
        "and update this script."
    )

patched_func = func_body[:last_idx] + NEW_BLOCK + func_body[last_idx + len(RETURN_MARKER):]
target.write_text(text[:start] + patched_func + text[end:])
print(f"==> gateway setup menu filtered to {ALLOWED_KEYS}")
PY

# --- #88: clarify tool tolerates a bare question object ---
# See ../../docker/patch-clarify-questions-array.py and
# ../../shared/model-notes.md's "clarify itself root-caused and fixed"
# section for the full root cause — applied to the native install's
# own copy of clarify_tool.py.
if [ ! -f "${CLARIFY_TOOL}" ]; then
  echo "!! ${CLARIFY_TOOL} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${CLARIFY_TOOL}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

old = '''    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

new = '''    if isinstance(questions, dict):
        # ka8t/Hermes: tolerate a single question object instead of a
        # one-entry array -- see macos-arm64/scripts/patch-native-hermes.sh /
        # docker/patch-clarify-questions-array.py (issue #88).
        questions = [questions]
    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

if new in text:
    print("==> clarify tool already tolerates a bare question object (#88) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> clarify tool patched to tolerate a bare question object (#88)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "shared/model-notes.md's clarify-loop section and update this "
        "script."
    )
PY

# --- #48: mandatory verify-before-success instruction in SOUL.md ---
# See ../../docker/Dockerfile and ../../shared/model-notes.md's #48 section.
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

# --- #48: delegation-fabrication stopgap disclaimer in SOUL.md ---
# See ../../docker/Dockerfile and ../../shared/model-notes.md's #48 section,
# and https://github.com/NousResearch/hermes-agent/issues/102977 (the
# upstream report for the durable fix). Unconditional stopgap: not a
# claim this closes the gap by itself.
DELEG_MARKER="Whenever your reply to the user relies on a delegate_task result"
if grep -qF "${DELEG_MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the delegation-disclaimer stopgap (#48) — left as is"
else
  printf '\n\nWhenever your reply to the user relies on a delegate_task result — whether or not it appears to have succeeded — append this exact note at the end of your message: "Note: this involved a delegated subtask; please verify the reported outcome independently before relying on it." Add it every time delegate_task was used this turn, with no exception for results that look successful.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched with delegation-disclaimer stopgap (#48)"
fi

# --- #75: zero-tool-call fabrication stopgap ---
# See ../../docker/Dockerfile's matching block for the full incident this
# addresses — a different failure mode than #48's: no tool call at all,
# not a checkable-but-fabricated one.
ZERO_TOOL_MARKER="you have not called any tool this turn to actually do it"
if grep -qF "${ZERO_TOOL_MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the zero-tool-call stopgap (#75) — left as is"
else
  printf '\n\nWhen the user asks you to build, create, deploy, or set up something, and you have not called any tool this turn to actually do it, you have NOT done it — no matter how detailed or confident your description sounds. Writing example code in a chat message is not creating it. Describing steps is not performing them. Saying "je comprends" to a request to do real work is not doing the work. Never give usage instructions for something that does not yet exist. If real work is needed: either call the appropriate tool now, or say plainly and specifically what still needs to be done and why you have not done it yet.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched with zero-tool-call stopgap (#75)"
fi

# --- #76: agent-creation skill routing ---
# See ../../docker/Dockerfile's matching block for the full incident —
# after #75's fix, the model calls tools but picks a mismatched existing
# skill instead of clarify-agent-intent/build-agent-from-intent.
AGENT_ROUTING_MARKER="maps specifically to the clarify-agent-intent"
if grep -qF "${AGENT_ROUTING_MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the agent-creation routing instruction (#76) — left as is"
else
  printf '\n\nWhen the user asks you to create or build an agent — not just to answer a question or look something up — that request maps specifically to the clarify-agent-intent and build-agent-from-intent skills. Start there. Recommending an existing unrelated skill (even a close-sounding one) instead of building the requested agent, or explaining to the user how they could do it themselves, does not fulfill an explicit '"'"'create an agent'"'"' request — it is a different, smaller answer to a bigger question.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched with agent-creation routing instruction (#76)"
fi
