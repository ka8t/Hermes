#!/usr/bin/env python3
"""Build-time patch — refuse to delegate an agent-creation request instead
of relying on the model to route it correctly on its own.

Root cause (issue #76, confirmed live 2026-09-15 via direct `state.db`
inspection across 6 sessions, macOS/Metal): when a user asks to "create an
agent"/"crée un agent", Llama-3.1-8B-Instruct calls `delegate_task`
immediately, with the raw or lightly-rephrased request as the child's
`goal` — WITHOUT first calling `skill_view(name="agent-intent-interview")`,
despite SOUL.md's explicit routing instruction telling it to "start there."
The spawned child never receives the "this is an agent-creation request"
framing (only the narrow decomposed goal, e.g. "send a daily message") and
picks an unrelated existing skill instead (`apple-notes` in one capture,
bare `execute_code` with no skill in another). `agent-intent-interview` was
mentioned 0 times across all 6 tested sessions and their subagents.

A prompt-level fix (reinforcing the same routing instruction in SOUL.md,
tested the same day) had ZERO measured effect over 3 clean runs — this
model has hit a real instruction-following ceiling on this specific
routing decision (consistent with its own measured BFCL scores,
`simple_python` 54.75%, `parallel` 52.50% — see shared/model-evaluation.md).

This is also the structurally correct fix, not just a workaround: the
agent-creation flow (`agent-intent-interview` -> `agent-profile-builder`)
is direct CLI action by the CURRENT agent (`hermes profile create`,
`hermes cron create`, ...) per those skills' own SKILL.md — never a task a
subagent can carry out. Delegating is the wrong operation for this goal,
independent of any framing it's given.

Fix: `delegate_task` itself detects an agent-creation-shaped `goal` (French
or English — the two languages actually seen in reproductions) at the TOP
level only (depth 0 — the conversational agent handing off its own turn,
not a subagent decomposing already-scoped work) and refuses with
`tool_error`, naming the two skills to consult instead. Verified live,
2026-09-15: after the refusal, the model correctly called
`skill_view(name="agent-intent-interview")` (previously 0/6 sessions);
confirmed no false positive on an unrelated, legitimate delegation request
("Search for 3 recent AI news articles" went through unblocked). Full
end-to-end profile creation after the redirect is NOT yet reliable — a
separate, harder follow-through problem, consistent with the same
instruction-following ceiling — see issue #76 for status.
"""
import pathlib
import re
import sys

TASKS_TARGET = pathlib.Path("/opt/hermes/tools/delegate_tool_tasks.py")
DELEGATE_TARGET = pathlib.Path("/opt/hermes/tools/delegate_tool.py")

tasks_text = TASKS_TARGET.read_text()

CONST_OLD = '''_MIN_BATCH_GOAL_LEN = 10'''

CONST_NEW = '''_MIN_BATCH_GOAL_LEN = 10

# ka8t/Hermes: a top-level goal that reads as "create/build a NEW agent"
# (French or English -- the two languages actually seen in reproductions of
# issue #76) must never be delegated. The agent-creation flow
# (agent-intent-interview -> agent-profile-builder) is direct CLI action by
# the CURRENT agent (`hermes profile create`, `hermes cron create`, ...), not
# a task a subagent can carry out -- a spawned child never receives the
# "this is an agent-creation request" framing and picks an unrelated skill
# instead (see issue #76). Indefinite article only ("a/an/un/une") -- "the
# agent" refers to the CURRENT agent, not a new one, and must not trigger
# this. See docker/patch-delegate-task-agent-creation-gate.py.
_AGENT_CREATION_RE = re.compile(
    r"\\b(cr[ée]e?r?|cr[ée]ez|cr[ée]ons|construire|configurer|mettre\\s+en\\s+place|"
    r"create|build|set\\s*up|spin\\s*up|make(?:\\s+me)?|configure|want)\\b"
    r"(?:\\s+\\w+){0,4}?\\s+(?:un|une|an?)\\b"
    r"(?:\\s+\\w+){0,2}?\\s+(agent|bot|assistant)\\b",
    re.IGNORECASE,
)


def _agent_creation_goal_match(goal: str) -> Optional[str]:
    m = _AGENT_CREATION_RE.search(goal)
    return m.group(0) if m else None'''

SIG_OLD = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

SIG_NEW = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int, depth: int = 0
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

GATE_OLD = '''        if not task.get("goal", "").strip():
            return None, f"Task {i} is missing a 'goal'."
    # The single-goal form is exempt from the batch gate (short goals are valid there).'''

GATE_NEW = '''        if not task.get("goal", "").strip():
            return None, f"Task {i} is missing a 'goal'."
    # Only at depth 0: the top-level agent handing off its OWN conversation
    # turn, not a subagent decomposing already-scoped work (see issue #76).
    if depth == 0:
        for i, task in enumerate(task_list):
            goal_text = str(task.get("goal", ""))
            if matched := _agent_creation_goal_match(goal_text):
                return None, (
                    f"Task {i} ({matched!r}) asks to create a new agent/bot/assistant. "
                    "Do not delegate this -- a subagent never gets the \\"this is an "
                    "agent-creation request\\" framing and will pick an unrelated skill "
                    "instead. Handle it yourself: call skill_view(name="
                    "\\"agent-intent-interview\\") first, then follow it through "
                    "skill_view(name=\\"agent-profile-builder\\") -- both are direct actions "
                    "for the current agent (hermes profile create, hermes cron create, "
                    "...), not a task to hand off."
                )
    # The single-goal form is exempt from the batch gate (short goals are valid there).'''

_missing = []
for label, old in (("constants", CONST_OLD), ("signature", SIG_OLD), ("gate", GATE_OLD)):
    if old not in tasks_text:
        _missing.append(label)
if _missing:
    sys.exit(
        f"delegate_tool_tasks.py doesn't match the expected text ({', '.join(_missing)}) "
        "-- the base image likely changed upstream. Re-check issue #76 and update this patch."
    )

tasks_text = tasks_text.replace(CONST_OLD, CONST_NEW, 1)
tasks_text = tasks_text.replace(SIG_OLD, SIG_NEW, 1)
tasks_text = tasks_text.replace(GATE_OLD, GATE_NEW, 1)
if "\nimport re\n" not in tasks_text and not re.search(r"^import re$", tasks_text, re.MULTILINE):
    tasks_text = tasks_text.replace("import json\n", "import json\nimport re\n", 1)
TASKS_TARGET.write_text(tasks_text)
print("Patched delegate_tool_tasks.py: _normalize_task_list() now refuses to delegate an agent-creation goal at depth 0.")

delegate_text = DELEGATE_TARGET.read_text()
CALL_OLD = (
    "    task_list, err = _normalize_task_list(goal, context, tasks, output_schema, top_role, max_children)"
)
CALL_NEW = (
    "    task_list, err = _normalize_task_list(goal, context, tasks, output_schema, top_role, max_children, depth)"
)
if CALL_OLD not in delegate_text:
    sys.exit(
        "delegate_tool.py's call to _normalize_task_list() doesn't match the "
        "expected text -- the base image likely changed upstream. Re-check "
        "issue #76 and update this patch."
    )
DELEGATE_TARGET.write_text(delegate_text.replace(CALL_OLD, CALL_NEW, 1))
print("Patched delegate_tool.py: _normalize_task_list() call now passes the caller's delegation depth.")
