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
("Search for 3 recent AI news articles" went through unblocked).

The error message is deliberately directive ("STOP", "your ONLY next
action") rather than a plain statement of the rule: a first version just
named the two skills and, live-tested, only got the model to actually
finish the CLI steps sometimes (it would re-delegate with a rephrased
goal, or narrate the plan instead of running it). The `_AGENT_CREATION_RE`
regex also gained an unconditional "hermes profile" branch after a live
capture where the retried goal ("Create a new Hermes profile for...")
dropped the word "agent" entirely and slipped through the original
pattern. With both changes, 1/3 fresh local runs completed the real
`hermes profile create` via `terminal` (verified: the profile existed on
disk); the other 2/3 attempted real execution (not just prose) but picked
the wrong mechanism (re-delegating, or a fabricated Python import instead
of the `terminal` tool) — a separate, harder execution-correctness problem
that remains open, not a regression of the routing fix itself.

**Iteration 3, same day: closing the goal-text whack-a-mole gap.** The
`_AGENT_CREATION_RE` check above only ever looks at the `goal` text the
model itself writes for the delegated task -- and the model can reword
that freely. Live-captured: after one refusal, a retry rephrased "Create a
daily reminder agent" into "send daily message" (no "agent" word at all)
and slipped straight past the regex, spawning an unguided subagent exactly
as issue #76 describes. `_origin_user_message_agent_creation_match()`
closes this by also matching against the CURRENT TURN's actual human
message (via `parent_agent._session_db.get_messages(...)`) -- the human
does not reword their own request between retries the way the model
rewords its `goal`, so this catches what the goal-only check misses.
Best-effort and additive: falls back to `None` (goal-only check still
applies) whenever session history isn't available, and never raises.
Verified live: 6/6 delegate_task attempts blocked in one turn, including
one whose `goal` text ("send...") would have slipped through the old
check alone -- confirmed via the refusal message itself, which named the
ORIGIN text ("Crée un agent") rather than the goal text, proving the new
path fired. No false positive observed on an unrelated legitimate
delegation prompt (regex match against that prompt's own text: none).
See issue #76 for current status.
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

SIG_OLD = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

SIG_NEW = '''def _normalize_task_list(
    goal, context, tasks, output_schema, top_role: str, max_children: int, depth: int = 0,
    parent_agent: Any = None,
) -> tuple[Optional[List[Dict[str, Any]]], Optional[str]]:'''

GATE_OLD = '''        if not task.get("goal", "").strip():
            return None, f"Task {i} is missing a 'goal'."
    # The single-goal form is exempt from the batch gate (short goals are valid there).'''

GATE_NEW = '''        if not task.get("goal", "").strip():
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
    "    task_list, err = _normalize_task_list(\n"
    "        goal, context, tasks, output_schema, top_role, max_children, depth, parent_agent,\n"
    "    )"
)
if CALL_OLD not in delegate_text:
    sys.exit(
        "delegate_tool.py's call to _normalize_task_list() doesn't match the "
        "expected text -- the base image likely changed upstream. Re-check "
        "issue #76 and update this patch."
    )
DELEGATE_TARGET.write_text(delegate_text.replace(CALL_OLD, CALL_NEW, 1))
print("Patched delegate_tool.py: _normalize_task_list() call now passes the caller's delegation depth.")
