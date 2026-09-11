#!/usr/bin/env python3
"""Build-time patch — make the `clarify` tool tolerate the two malformed
shapes this model actually sends for `questions` instead of a real array.

**Shape 1, confirmed live 2026-09-10** (a Telegram "Bonjour" test,
reproduced 8 times in a row before hermes-agent's own loop guardrail
forced a stop): Llama-3.1-8B-Instruct calls `clarify` with `questions`
as a bare object (`{"question": "..."}`) instead of the schema's
required one-entry array (`[{"question": "..."}]`).

**Shape 2, confirmed live 2026-09-11** (a CLI oneshot smoke test after
fixing shape 1): the same model instead sends `questions` as a **JSON
string containing the array**, properly escaped
(`"[{\\"question\\": \\"...\\"}]"`) rather than a native JSON array
value — the exact same double-encoding mistake already documented in
shared/model-notes.md for `delegate_task`'s `tasks` param and
`skill_manage`'s `operations` param, now confirmed on `clarify` too, in
a different specific shape than shape 1. Reproduced 9/9 times across a
Telegram session and two separate CLI oneshots before being root-caused
by reading the raw `tool_calls` JSON directly from state.db (not
assumed from the generic error message, which is identical for both
shapes).

Neither is a schema bug — CLARIFY_SCHEMA in tools/clarify_tool.py
already says plainly "a single question is a one-entry array"; this is
the model not reliably following its own tool schema, in two different
ways.

hermes-agent's own tool-call loop guardrail (agent/tool_guardrails.py)
explicitly instructs the model to "keep using tools" rather than fall
back to a plain-text reply once it's mid-loop, so a single malformed
`clarify` call escalates into a multi-minute retry loop (warned at 3
failures, hard-stopped at 8) for a message that never needed any tool
at all — see shared/hardware-sizing.md's 2026-09-10 incident.

`_normalize_questions()` already tolerates a bare-string item inside an
otherwise-valid array (`["Q1?"]` -> `[{"question": "Q1?"}]`) — this
patch extends the same one-argument-shape tolerance one level up,
handling both malformed shapes before the existing array-type check
runs: a bare dict becomes a one-entry array, and a string is tried as
JSON first (used if it decodes to a list or dict) before falling
through to the original rejection for anything genuinely invalid.
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/tools/clarify_tool.py")
text = TARGET.read_text()

OLD = '''    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

NEW = '''    if isinstance(questions, str):
        # ka8t/Hermes: tolerate `questions` sent as a JSON-encoded string
        # instead of a native array -- confirmed live, 2026-09-11,
        # Llama-3.1-8B double-encodes the array as a string
        # (`"[{\\"question\\": ...}]"`), the same class of mistake already
        # documented in shared/model-notes.md for delegate_task/
        # skill_manage's array params. Only used if it actually decodes to
        # a list or dict; anything else falls through to the original
        # rejection below. See docker/patch-clarify-questions-array.py.
        import json as _json
        try:
            _decoded = _json.loads(questions)
        except (ValueError, TypeError):
            _decoded = None
        if isinstance(_decoded, (list, dict)):
            questions = _decoded
    if isinstance(questions, dict):
        # ka8t/Hermes: tolerate a single question object instead of a
        # one-entry array -- confirmed live, 2026-09-10, Llama-3.1-8B
        # repeatedly calls `clarify` with `questions` as a bare object
        # instead of `[{...}]`, hitting this exact error on effectively
        # every first clarify call, looping until hermes-agent's own
        # same_tool_failure_halt (8 failures) forces a stop. The schema
        # already says "a single question is a one-entry array" but this
        # model doesn't reliably follow it. See
        # docker/patch-clarify-questions-array.py.
        questions = [questions]
    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

if OLD not in text:
    sys.exit(
        "clarify_tool.py's _normalize_questions() doesn't match the "
        "expected text -- the base image likely changed upstream. "
        "Re-check shared/model-notes.md's clarify-loop section and "
        "update this patch."
    )

TARGET.write_text(text.replace(OLD, NEW, 1))
print("Patched clarify_tool.py: _normalize_questions() now accepts a bare question object or a JSON-encoded string.")
