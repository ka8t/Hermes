#!/usr/bin/env python3
"""Build-time patch — make the `clarify` tool tolerate a single question
object where `questions` should be a one-entry array.

Confirmed live, 2026-09-10 (a Telegram "Bonjour" test, reproduced 8
times in a row before hermes-agent's own loop guardrail forced a stop):
Llama-3.1-8B-Instruct calls `clarify` with `questions` as a bare object
(`{"question": "..."}`) instead of the schema's required one-entry array
(`[{"question": "..."}]`) on effectively every first clarify call,
regardless of session/memory state (reproduced against both a week-old
polluted session and a genuinely fresh one with cleared memory) — this
is the model not reliably following its own tool schema
(CLARIFY_SCHEMA in tools/clarify_tool.py already says plainly "a single
question is a one-entry array"), not a schema bug.

hermes-agent's own tool-call loop guardrail (agent/tool_guardrails.py)
explicitly instructs the model to "keep using tools" rather than fall
back to a plain-text reply once it's mid-loop, so a single malformed
`clarify` call escalates into a multi-minute retry loop (warned at 3
failures, hard-stopped at 8) for a message that never needed any tool
at all — see shared/hardware-sizing.md's 2026-09-10 incident.

`_normalize_questions()` already tolerates a bare-string item inside an
otherwise-valid array (`["Q1?"]` -> `[{"question": "Q1?"}]`) — this
patch extends the same one-argument-shape tolerance one level up: a
bare dict for the whole `questions` param becomes a one-entry array
before the existing array-type check runs, so the single most common
malformed shape from this model succeeds instead of erroring and
triggering the loop guardrail.
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/tools/clarify_tool.py")
text = TARGET.read_text()

OLD = '''    if not isinstance(questions, list):
        return None, "questions must be an array of question objects."'''

NEW = '''    if isinstance(questions, dict):
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
print("Patched clarify_tool.py: _normalize_questions() now accepts a bare question object.")
