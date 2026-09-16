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

# --- #88/#100: clarify tool tolerates a bare question object or a
#     JSON-encoded string ---
# See ../../docker/patch-clarify-questions-array.py and
# ../../shared/model-notes.md's "clarify itself root-caused and fixed"
# section for the full root cause — applied to the native install's
# own copy of clarify_tool.py. Was #88-only (bare object) until
# 2026-09-15, when this script was found to have silently never picked
# up #100's later JSON-string-shape fix, even though the Docker path
# had it — re-run this after any prior run to pick up the missing shape.
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

new = '''    if isinstance(questions, str):
        # ka8t/Hermes: tolerate `questions` sent as a JSON-encoded string
        # instead of a native array -- see
        # macos-arm64/scripts/patch-native-hermes.sh /
        # docker/patch-clarify-questions-array.py (issue #100).
        import json as _json
        try:
            _decoded = _json.loads(questions)
        except (ValueError, TypeError):
            _decoded = None
        if isinstance(_decoded, (list, dict)):
            questions = _decoded
    if isinstance(questions, dict):
        # ka8t/Hermes: tolerate a single question object instead of a
        # one-entry array -- see macos-arm64/scripts/patch-native-hermes.sh /
        # docker/patch-clarify-questions-array.py (issue #88).
        questions = [questions]
    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

if new in text:
    print("==> clarify tool already tolerates a bare question object and a JSON string (#88/#100) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> clarify tool patched to tolerate a bare question object and a JSON string (#88/#100)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "shared/model-notes.md's clarify-loop section and update this "
        "script."
    )
PY

# --- #102: delegate_task/skill_manage tolerate a string-encoded array ---
# See ../../docker/patch-delegate-task-tasks-array.py,
# ../../docker/patch-skill-manage-operations-array.py, and issue #102
# for the full root cause — applied to the native install's own copies.
DELEGATE_TASKS_TOOL="${INSTALL_ROOT}/tools/delegate_tool_tasks.py"
if [ ! -f "${DELEGATE_TASKS_TOOL}" ]; then
  echo "!! ${DELEGATE_TASKS_TOOL} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${DELEGATE_TASKS_TOOL}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

old = '''    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        return None, f"tasks must be a JSON array of task objects; received a string that could not be parsed as JSON ({exc.msg})."'''

new = '''    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        # ka8t/Hermes: tolerate Python-literal syntax (single-quoted
        # strings) instead of real JSON -- see
        # macos-arm64/scripts/patch-native-hermes.sh /
        # docker/patch-delegate-task-tasks-array.py (issue #102).
        import ast
        try:
            parsed = ast.literal_eval(raw)
        except (ValueError, SyntaxError):
            return None, f"tasks must be a JSON array of task objects; received a string that could not be parsed as JSON ({exc.msg})."'''

if new in text:
    print("==> delegate_task already tolerates a Python-literal tasks string (#102) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> delegate_task patched to tolerate a Python-literal tasks string (#102)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "issue #102 and update this script."
    )
PY

SKILL_MANAGER_BATCH="${INSTALL_ROOT}/tools/skill_manager_batch.py"
if [ ! -f "${SKILL_MANAGER_BATCH}" ]; then
  echo "!! ${SKILL_MANAGER_BATCH} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${SKILL_MANAGER_BATCH}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

old = '''    from tools import skill_manager_tool as _smt
    from tools.registry import tool_error
    if not isinstance(operations, list) or not operations:
        return tool_error("operations must be a non-empty array.", success=False)'''

new = '''    from tools import skill_manager_tool as _smt
    from tools.registry import tool_error
    if isinstance(operations, str):
        # ka8t/Hermes: tolerate `operations` sent as a string instead of
        # a real array -- see macos-arm64/scripts/patch-native-hermes.sh /
        # docker/patch-skill-manage-operations-array.py (issue #102).
        import ast
        _raw = operations.strip()
        _decoded = None
        try:
            _decoded = json.loads(_raw)
        except (ValueError, TypeError):
            try:
                _decoded = ast.literal_eval(_raw)
            except (ValueError, SyntaxError):
                _decoded = None
        if isinstance(_decoded, list):
            operations = _decoded
    if not isinstance(operations, list) or not operations:
        return tool_error("operations must be a non-empty array.", success=False)'''

if new in text:
    print("==> skill_manage already tolerates a string-encoded operations array (#102) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> skill_manage patched to tolerate a string-encoded operations array (#102)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "issue #102 and update this script."
    )
PY

# --- #76: delegate_task refuses to delegate agent-creation requests ---
# See ../../docker/patch-delegate-task-agent-creation-gate.py and issue #76
# for the full root cause — applied to the native install's own copies.
python3 - "${DELEGATE_TASKS_TOOL}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

const_old = '''_MIN_BATCH_GOAL_LEN = 10'''

const_new = '''_MIN_BATCH_GOAL_LEN = 10

# ka8t/Hermes: a top-level goal that reads as "create/build a NEW agent"
# (French or English -- the two languages actually seen in reproductions of
# issue #76) must never be delegated. The agent-creation flow
# (agent-intent-interview -> agent-profile-builder) is direct CLI action by
# the CURRENT agent (`hermes profile create`, `hermes cron create`, ...), not
# a task a subagent can carry out -- a spawned child never receives the
# "this is an agent-creation request" framing and picks an unrelated skill
# instead (see issue #76). Indefinite article only ("a/an/un/une") -- "the
# agent" refers to the CURRENT agent, not a new one, and must not trigger
# this. See ../../docker/patch-delegate-task-agent-creation-gate.py.
_AGENT_CREATION_RE = re.compile(
    r"\\b(cr[ée]e?r?|cr[ée]ez|cr[ée]ons|construire|configurer|mettre\\s+en\\s+place|"
    r"create|build|set\\s*up|spin\\s*up|make(?:\\s+me)?|configure|want)\\b"
    r"(?:\\s+\\w+){0,4}?\\s+(?:un|une|an?)\\b"
    r"(?:\\s+\\w+){0,2}?\\s+(agent|bot|assistant)\\b"
    # ka8t/Hermes: "hermes profile" is this deployment's own name for what an
    # "agent" request resolves to (agent-profile-builder's own vocabulary,
    # `hermes profile create`) -- a rephrased continuation after the first
    # gate hit ("create a new Hermes profile for...") still needs catching,
    # unconditionally, since a delegated subagent goal legitimately needing
    # this exact phrase is not a realistic case on this deployment.
    r"|\\bhermes\\s+profile\\b",
    re.IGNORECASE,
)


def _agent_creation_goal_match(goal: str) -> Optional[str]:
    m = _AGENT_CREATION_RE.search(goal)
    return m.group(0) if m else None


def _origin_user_message_agent_creation_match(parent_agent: Any) -> Optional[str]:
    """Match against the CURRENT TURN's actual human message, not the model's own
    (freely rewordable) ``goal`` text -- the whack-a-mole gap in the goal-only check:
    live-captured 2026-09-15, a retry after the first refusal rephrased "Create a
    daily reminder agent" into "send daily message" / "Create a new Hermes profile
    for..." and slipped past every goal-text pattern tried, while the human's own
    message stayed exactly the same word for word across every retry in that turn.
    Best-effort: returns ``None`` (no opinion, caller falls back to the goal-only
    check) whenever session history isn't available -- never raises, since this must
    not be able to break delegate_task for deployments/sessions without persistence.
    """
    session_db = getattr(parent_agent, "_session_db", None)
    session_id = getattr(parent_agent, "session_id", None)
    if session_db is None or not session_id:
        return None
    try:
        recent = session_db.get_messages(session_id, limit=10, latest=True)
    except Exception:
        return None
    for msg in reversed(recent or []):
        if isinstance(msg, dict) and msg.get("role") == "user":
            content = msg.get("content")
            return _agent_creation_goal_match(content) if isinstance(content, str) else None
    return None'''

sig_old = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

sig_new = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int, depth: int = 0,
    parent_agent: Any = None,
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

gate_old = '''        if not task.get("goal", "").strip():
            return None, f"Task {i} is missing a 'goal'."
    # The single-goal form is exempt from the batch gate (short goals are valid there).'''

gate_new = '''        if not task.get("goal", "").strip():
            return None, f"Task {i} is missing a 'goal'."
    # Only at depth 0: the top-level agent handing off its OWN conversation
    # turn, not a subagent decomposing already-scoped work (see issue #76).
    if depth == 0:
        origin_matched = _origin_user_message_agent_creation_match(parent_agent)
        for i, task in enumerate(task_list):
            goal_text = str(task.get("goal", ""))
            if matched := (_agent_creation_goal_match(goal_text) or origin_matched):
                return None, (
                    f"Task {i} ({matched!r}) asks to create a new agent/bot/assistant. "
                    "STOP -- do not call delegate_task again for this, and do not just "
                    "describe the steps in a chat reply. Your ONLY next action: call "
                    "skill_view(name=\\"agent-intent-interview\\") right now. A subagent "
                    "never gets the \\"this is an agent-creation request\\" framing and "
                    "will pick an unrelated skill instead -- this is not delegatable. "
                    "After agent-intent-interview's questions are answered, its content "
                    "will tell you to move to skill_view(name=\\"agent-profile-builder\\") "
                    "-- that skill's steps (hermes profile create, hermes cron create, "
                    "...) are commands YOU must run yourself via execute_code/terminal, "
                    "not text to show the user."
                )
    # The single-goal form is exempt from the batch gate (short goals are valid there).'''

if gate_new in text:
    print("==> delegate_task already refuses agent-creation goals at depth 0 (#76) — left as is")
elif const_old in text and sig_old in text and gate_old in text:
    text = text.replace(const_old, const_new, 1)
    text = text.replace(sig_old, sig_new, 1)
    text = text.replace(gate_old, gate_new, 1)
    target.write_text(text)
    print("==> delegate_task patched to refuse agent-creation goals at depth 0 (#76)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "issue #76 and update this script."
    )
PY

DELEGATE_TOOL="${INSTALL_ROOT}/tools/delegate_tool.py"
if [ ! -f "${DELEGATE_TOOL}" ]; then
  echo "!! ${DELEGATE_TOOL} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${DELEGATE_TOOL}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

old = '''    task_list, err = _normalize_task_list(goal, context, tasks, output_schema, top_role, max_children)'''
new = '''    task_list, err = _normalize_task_list(
        goal, context, tasks, output_schema, top_role, max_children, depth, parent_agent,
    )'''

if new in text:
    print("==> delegate_task already passes delegation depth to _normalize_task_list (#76) — left as is")
elif old in text:
    target.write_text(text.replace(old, new, 1))
    print("==> delegate_task patched to pass delegation depth to _normalize_task_list (#76)")
else:
    sys.exit(
        f"!! {target} doesn't match the expected text — the installed "
        "hermes-agent version may have changed this file. Check "
        "issue #76 and update this script."
    )
PY

# --- #101: recover a fabricated tool-call JSON blob from content ---
# See ../../docker/patch-chat-completions-recover-tool-call.py and issue #101
# for the full root cause — applied to the native install's own copy.
CHAT_COMPLETIONS_TRANSPORT="${INSTALL_ROOT}/agent/transports/chat_completions.py"
if [ ! -f "${CHAT_COMPLETIONS_TRANSPORT}" ]; then
  echo "!! ${CHAT_COMPLETIONS_TRANSPORT} not found — run ./install-hermes-native.sh first." >&2
  exit 1
fi
python3 - "${CHAT_COMPLETIONS_TRANSPORT}" <<'PY'
import pathlib, sys

target = pathlib.Path(sys.argv[1])
text = target.read_text()

import_old = '''import json
from typing import Any
'''

import_new = '''import json
import re
from typing import Any
'''

module_consts_old = '''
class ChatCompletionsTransport(ProviderTransport):
'''

module_consts_new = '''
# ka8t/Hermes: raw chat-template artifacts --skip-chat-parsing exposes when a
# recovered tool call's remaining content is nothing but this -- see
# _recover_fabricated_tool_call (issue #101).
_JUNK_REMAINDER_RE = re.compile(r"^(assistant|user|system)$|^```(?:\\w+)?\\s*```$", re.IGNORECASE)
_LEADING_ROLE_MARKER_RE = re.compile(r"^(assistant|user|system)\\s*:?\\s*\\n*", re.IGNORECASE)


class ChatCompletionsTransport(ProviderTransport):
'''

methods_old = '''
    def normalize_response(self, response: Any, **kwargs) -> NormalizedResponse:
'''

methods_new = '''
    def _find_json_object(self, text: str, start: int = 0) -> "tuple[int, int] | None":
        """Span of the first top-level ``{...}`` object in ``text`` from ``start``,
        respecting string literals so braces inside quoted strings don't confuse the
        scan. Returns ``(open_idx, close_idx)`` (inclusive) or ``None`` -- ``None`` also
        for unbalanced input (e.g. a response truncated mid-JSON), which is the correct
        outcome: nothing safe to recover there."""
        open_idx = text.find("{", start)
        if open_idx == -1:
            return None
        depth = 0
        in_string = False
        escape = False
        for i in range(open_idx, len(text)):
            ch = text[i]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return open_idx, i
        return None

    @staticmethod
    def _parse_tool_call_json(raw: str) -> "dict | None":
        """``raw`` (a balanced ``{...}`` span) as a ``{"name": ..., "parameters"|
        "arguments": {...}}`` dict, tolerating Python-literal (single-quoted) syntax
        the same way the delegate_task/skill_manage tool patches do -- or ``None`` if
        it doesn't parse or doesn't have that shape."""
        try:
            parsed = json.loads(raw)
        except (ValueError, TypeError):
            import ast
            try:
                parsed = ast.literal_eval(raw)
            except (ValueError, SyntaxError):
                return None
        if not isinstance(parsed, dict):
            return None
        name = parsed.get("name")
        if not isinstance(name, str) or not name.strip():
            return None
        args = parsed.get("parameters", parsed.get("arguments"))
        if args is None:
            args = {}
        if not isinstance(args, dict):
            return None
        return {"name": name, "arguments": args}

    def _recover_fabricated_tool_call(self, content: str) -> "tuple[ToolCall | None, str | None]":
        """ka8t/Hermes: a weak model sometimes writes its tool-call intent directly in
        chat content as ``{"name": "...", "parameters"|"arguments": {...}}`` instead of
        a real function call -- observed live with llama.cpp's strict `peg-native`
        chat-format parser rejecting this exact mixed shape outright (`openai.APIError:
        ... does not match the expected peg-native format`, issue #101, reproduced
        repeatedly with this deployment's default model). Recovering it here, once,
        generically for any OpenAI-compatible provider, means a genuine tool-call intent
        gets executed instead of being lost to a parse error or shown to the user as
        inert JSON. Conservative by construction -- returns ``(None, None)`` unless the
        text contains a JSON object with exactly this shape, since ordinary prose
        essentially never does.

        Only the FIRST such object becomes the real, executed tool call. Observed live:
        a generation sometimes strings several of these together in one response
        (``{"name": "skill_view", ...}; {"name": "execute_code", ...}; {"name":
        "browser_vault_save_login", ...}``) -- whether this is deliberate or not isn't
        knowable from the text alone, but in the captured examples the later fragments
        were incoherent with each other (one referenced a Python API,
        `hermes.skill.create_daily_reminder()`, that doesn't exist anywhere in this
        codebase) and unrelated to the request. Executing an unverified multi-action
        bundle from a model with a measured ~52% BFCL score on genuine parallel calls
        is a real risk independent of intent -- one of the actions seen live was a
        password-vault write. Every object after the first matching this shape is
        stripped as noise -- never shown to the user, never executed -- while genuine
        surrounding prose (e.g. the mandatory delegated-subtask disclaimer) is kept.
        """
        if not isinstance(content, str) or not content.strip():
            return None, None
        first_call = None
        pieces: list[str] = []
        cursor = 0
        while True:
            span = self._find_json_object(content, cursor)
            if span is None:
                pieces.append(content[cursor:])
                break
            start, end = span
            pieces.append(content[cursor:start])
            raw = content[start:end + 1]
            parsed = self._parse_tool_call_json(raw)
            if parsed is not None:
                if first_call is None:
                    first_call = parsed
                # else: a later fragment shaped like a tool call -- drop it, don't execute or show it.
            else:
                pieces.append(raw)  # not a tool call after all -- keep as ordinary text.
            cursor = end + 1
        if first_call is None:
            return None, None
        remaining = "".join(pieces).strip()
        # ka8t/Hermes: --skip-chat-parsing (issue #101) exposes raw chat-template
        # leakage the native parser used to strip -- observed live: the word
        # "assistant" (the next turn's role marker, generated as literal text, no
        # special tokens involved -- confirmed via hex dump), either alone trailing
        # the JSON, or as a leading prefix before otherwise-genuine trailing prose
        # (e.g. "assistant\\n\\n Note: this involved a delegated subtask..."), and an
        # empty ```json``` fence. None of this is real content; keeping it would
        # show the user garbage and, combined with an empty synthetic tool result,
        # risks two effectively-empty "assistant" turns in a row.
        remaining = _LEADING_ROLE_MARKER_RE.sub("", remaining).strip()
        # Separators left over between stripped fragments (";", ",", stray whitespace).
        remaining = re.sub(r"^[;,\\s]+", "", remaining).strip()
        if remaining and _JUNK_REMAINDER_RE.match(remaining):
            remaining = ""
        return (
            ToolCall(id=None, name=first_call["name"],
                     arguments=json.dumps(first_call["arguments"], ensure_ascii=False),
                     provider_data={"recovered_from_content": True}),
            remaining or None,
        )

    def normalize_response(self, response: Any, **kwargs) -> NormalizedResponse:
'''

recovery_call_old = '''                    finish_reason = "content_filter"

'''

recovery_call_new = '''                    finish_reason = "content_filter"

        # ka8t/Hermes: see _recover_fabricated_tool_call -- issue #101.
        if not tool_calls:
            recovered, remaining = self._recover_fabricated_tool_call(content)
            if recovered is not None:
                tool_calls = [recovered]
                content = remaining
                finish_reason = "tool_calls"

'''

if recovery_call_new in text:
    print("==> chat_completions.py already recovers a fabricated tool-call JSON blob (#101) — left as is")
else:
    _missing = []
    for _label, _old in (("import", import_old), ("module_consts", module_consts_old), ("methods", methods_old), ("recovery_call", recovery_call_old)):
        if _old not in text:
            _missing.append(_label)
    if _missing:
        sys.exit(
            f"!! {target} doesn't match the expected text ({', '.join(_missing)}) — the "
            "installed hermes-agent version may have changed this file. Check "
            "issue #101 and update this script."
        )
    text = text.replace(import_old, import_new, 1)
    text = text.replace(module_consts_old, module_consts_new, 1)
    text = text.replace(methods_old, methods_new, 1)
    text = text.replace(recovery_call_old, recovery_call_new, 1)
    target.write_text(text)
    print("==> chat_completions.py patched to recover a fabricated tool-call JSON blob from content (#101)")
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
# skill instead of agent-intent-interview/agent-profile-builder.
AGENT_ROUTING_MARKER="maps specifically to the agent-intent-interview"
if grep -qF "${AGENT_ROUTING_MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the agent-creation routing instruction (#76) — left as is"
else
  printf '\n\nWhen the user asks you to create or build an agent — not just to answer a question or look something up — that request maps specifically to the agent-intent-interview and agent-profile-builder skills. Start there. Recommending an existing unrelated skill (even a close-sounding one) instead of building the requested agent, or explaining to the user how they could do it themselves, does not fulfill an explicit '"'"'create an agent'"'"' request — it is a different, smaller answer to a bigger question.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched with agent-creation routing instruction (#76)"
fi

# --- #101: no fabricated tool-call JSON in chat content ---
# See https://github.com/ka8t/Hermes/issues/101. Confirmed live: naming
# agent-intent-interview/agent-profile-builder in #76's routing instruction,
# combined with #48's "append this note whenever a reply relies on
# delegate_task" disclaimer, makes this model fabricate a fake single-
# function tool call as plain chat text (e.g. {"name":
# "agent-intent-interview", "parameters": {...}}) followed by the mandated
# disclaimer -- llama-server's PEG_NATIVE chat-format parser then rejects
# the mixed JSON-plus-prose output with "The model produced output that
# does not match the expected peg-native format" (a 500 from llama-server
# itself). Reproduces with or without array-typed parameters, so this is
# not the upstream python_array() whitespace bug (ggml-org/llama.cpp#27295)
# -- see the issue for the full trace. General instruction, not per-skill:
# shifting the routing names alone (as tried first) only moved the same
# fabrication from one skill to the next in the chain.
FAKE_TOOL_MARKER="never represent a tool call as JSON or code in your reply text"
if grep -qF "${FAKE_TOOL_MARKER}" "${SOUL_MD}"; then
  echo "==> SOUL.md already has the no-fabricated-tool-call instruction (#101) — left as is"
else
  printf '\n\nYou never represent a tool call as JSON or code in your reply text — not a real one, not an attempted one, not an example. If you intend to use a tool (delegate_task included, and handing off to a skill such as agent-intent-interview or agent-profile-builder), call it through the real function-calling mechanism, not by writing its name and arguments as text in your message. If you are not calling a tool this turn, write your reply as plain prose with no JSON-shaped fragment resembling one.' \
    >> "${SOUL_MD}"
  echo "==> SOUL.md patched with no-fabricated-tool-call instruction (#101)"
fi
