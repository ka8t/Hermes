#!/usr/bin/env python3
"""Build-time patch — make `delegate_task` tolerate `tasks` sent as a
Python-literal string instead of a real JSON array.

Confirmed live, 2026-09-15 (a real "crée un agent qui me résume les
nouveautés IA" request, macOS/Metal, `--skip-chat-parsing` and raw
state.db inspection): Llama-3.1-8B-Instruct sends `tasks` as a string
like `"[{'goal': '...', 'context': '...'}]"` — Python `repr()` syntax
(single-quoted), not JSON (double-quoted) — often enough to be a
significant contributing cause of the `delegate_task` retry loops
documented in issue #102 (same_tool_failure_warning firing repeatedly,
hermes-agent's loop guardrail eventually giving up). The existing
`_recover_tasks_from_json_string()` in tools/delegate_tool_tasks.py
only ever tried `json.loads()`, which always rejects Python-literal
syntax outright (`Expecting property name enclosed in double quotes`).

This is the exact same class of double-encoding mistake already
documented in shared/model-notes.md and already patched on `clarify`'s
`questions` param (see patch-clarify-questions-array.py) — now
confirmed on `delegate_task`'s `tasks` too, in a Python-literal variant
rather than clarify's JSON-string variant.

Fix: after `json.loads()` fails, try `ast.literal_eval()` before giving
up. `ast.literal_eval` only ever evaluates literal Python data
structures (str/bytes/num/tuple/list/dict/set/bool/None) — never
arbitrary code — so this is safe against a malicious or malformed
string. Verified against 3 real captured failures from this incident:
1 was well-formed Python-literal syntax (now recovered correctly), 2
were genuinely truncated mid-generation (still correctly rejected —
this patch doesn't and can't fix a truncated call, only a
wrong-but-complete one).
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/tools/delegate_tool_tasks.py")
text = TARGET.read_text()

OLD = '''    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        return None, f"tasks must be a JSON array of task objects; received a string that could not be parsed as JSON ({exc.msg})."'''

NEW = '''    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        # ka8t/Hermes: tolerate Python-literal syntax (single-quoted
        # strings) instead of real JSON -- confirmed live, 2026-09-15,
        # Llama-3.1-8B sends `tasks` as a string like
        # "[{'goal': '...', 'context': '...'}]" (Python repr shape, not
        # JSON) often enough to be the dominant cause of delegate_task
        # loop failures (issue #102). ast.literal_eval only evaluates
        # literal Python data structures -- never arbitrary code -- so
        # this is safe against a malicious/malformed string. Falls
        # through to the original JSON error below if literal_eval also
        # fails (e.g. the string is genuinely truncated mid-generation,
        # a separate, still-open failure mode). See
        # docker/patch-delegate-task-tasks-array.py.
        import ast
        try:
            parsed = ast.literal_eval(raw)
        except (ValueError, SyntaxError):
            return None, f"tasks must be a JSON array of task objects; received a string that could not be parsed as JSON ({exc.msg})."'''

if OLD not in text:
    sys.exit(
        "delegate_tool_tasks.py's _recover_tasks_from_json_string() "
        "doesn't match the expected text -- the base image likely "
        "changed upstream. Re-check issue #102 and update this patch."
    )

TARGET.write_text(text.replace(OLD, NEW, 1))
print("Patched delegate_tool_tasks.py: _recover_tasks_from_json_string() now accepts Python-literal syntax as a fallback.")
