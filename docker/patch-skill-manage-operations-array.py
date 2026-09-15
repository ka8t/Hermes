#!/usr/bin/env python3
"""Build-time patch — make `skill_manage`'s batch path tolerate
`operations` sent as a string (JSON-encoded or Python-literal) instead
of a real array.

Confirmed live, 2026-09-15, same incident as
patch-delegate-task-tasks-array.py (issue #102): `skill_manage` failed
repeatedly ("skill_manage has failed 5 times with identical arguments")
alongside `delegate_task`'s failures during the same test. Unlike
`delegate_task`, `_skill_manage_batch()` in
tools/skill_manager_batch.py had ZERO string-recovery attempt at all —
a bare `isinstance(operations, list)` check rejects a string outright
with a generic "operations must be a non-empty array" error, no
`json.loads()` attempt even for a well-formed JSON-encoded string.

Same class of double-encoding mistake documented in
shared/model-notes.md for both `delegate_task`'s `tasks` and this
tool's `operations`, and already patched on `clarify`'s `questions` —
see patch-clarify-questions-array.py and
patch-delegate-task-tasks-array.py for the sibling fixes.

Fix: before the type check, if `operations` is a string, try
`json.loads()` then `ast.literal_eval()` (safe -- only evaluates
literal Python data structures, never arbitrary code) and use the
result if it's a list. Falls through to the original rejection
unchanged if neither parser produces a list.
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/tools/skill_manager_batch.py")
text = TARGET.read_text()

OLD = '''    from tools import skill_manager_tool as _smt
    from tools.registry import tool_error
    if not isinstance(operations, list) or not operations:
        return tool_error("operations must be a non-empty array.", success=False)'''

NEW = '''    from tools import skill_manager_tool as _smt
    from tools.registry import tool_error
    if isinstance(operations, str):
        # ka8t/Hermes: tolerate `operations` sent as a string instead of a
        # real array -- confirmed live, 2026-09-15, Llama-3.1-8B sends
        # this as JSON-encoded text or as Python-literal syntax
        # (single-quoted, e.g. "[{'action': 'create', ...}]") often
        # enough to be a contributing cause of skill_manage loop
        # failures (issue #102) -- same class of bug already tolerated
        # for delegate_task's `tasks` param, see
        # tools/delegate_tool_tasks.py's matching comment. Falls through
        # to the original rejection below if neither parser succeeds.
        # See docker/patch-skill-manage-operations-array.py.
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

if OLD not in text:
    sys.exit(
        "skill_manager_batch.py's _skill_manage_batch() doesn't match "
        "the expected text -- the base image likely changed upstream. "
        "Re-check issue #102 and update this patch."
    )

TARGET.write_text(text.replace(OLD, NEW, 1))
print("Patched skill_manager_batch.py: _skill_manage_batch() now accepts a JSON-encoded or Python-literal string for operations.")
