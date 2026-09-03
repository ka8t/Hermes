---
name: clarify-agent-intent
description: Interview the user before creating a new Hermes profile/agent, so the result matches what they actually meant instead of a guess.
version: 1.0.0
author: ka8t/Hermes
license: MIT
metadata:
  hermes:
    tags: [profiles, onboarding, agent-creation]
    related_skills: [build-agent-from-intent]
---

# Clarify Agent Intent

Implements issue https://github.com/ka8t/Hermes/issues/2 — the first half of
the guided agent creation flow.

## When to Use

The user's message expresses intent to create a new agent, assistant, or
profile — phrases like "create an agent that...", "I want an agent for...",
"set up a bot to...", "make me an assistant that...". Do **not** use this
skill for a normal task request to the *current* agent ("find me flights to
Rome") — only when a genuinely new, separate profile is being proposed.

## Procedure

1. **Read the initial request for what it already answers.** Don't ask a
   question the user already answered in their first message.
2. **Ask, in a single plain chat message, only the questions still open**,
   from this list (skip any already answered). Do **not** use the built-in
   `clarify` tool for this: on messaging platforms it falls back to asking
   its `questions` one at a time anyway (defeating the single-message
   batching this step relies on), and smaller local models have been
   observed sending its `questions` parameter as something other than a
   real JSON array — causing the call to fail outright with "questions
   must be an array of question objects." A plain chat message listing the
   open questions has neither failure mode.
   - **Purpose/scope**: what should this agent actually do, concretely?
     ("watch my inbox for invoices" is concrete; "help with email" is not —
     push for the concrete version.)
   - **Channel(s)**: how should the user reach it, or it reach the user —
     Telegram, another already-configured gateway, or chat-only (no
     proactive messages)? Check what's actually connected on this
     deployment (`hermes doctor` or the channels list) rather than
     assuming.
   - **Cadence**: on-demand only, or a recurring schedule (and roughly how
     often)?
   - **Model needs**: does the deployment's default model suffice, or does
     this task justify a different one (cheaper/faster for high-volume
     simple work, or stronger for complex reasoning)? Check what's actually
     available (`/model` or the configured models list) rather than naming
     one that may not exist on this deployment.
   - **Data/tool access**: anything beyond the defaults — a specific
     mailbox, an API key, a skill it should start with.
3. **If a known template fits the description** (see `../templates/`),
   name it and ask whether to start from it rather than from scratch — this
   can shortcut most of the questions above.
4. **Do not create, modify, or configure anything yourself.** Once every
   point above is answered (or explicitly declined), hand off the finished
   spec to the `build-agent-from-intent` skill.

## Output

A short spec in this shape, either stated back to the user for confirmation
or passed directly into `build-agent-from-intent` in the same turn:

```
Agent: <name>
Purpose: <one or two concrete sentences>
Template: <template name, or "from scratch">
Channel: <telegram | none | ...>
Schedule: <on-demand | cron expression / plain-language cadence>
Model: <default | specific model id, see managing-models.md>
Extra access: <none | specifics>
```

## Pitfalls

- Asking one question per message turns a quick setup into an interrogation
  — batch the open questions into one message.
- Don't reach for the `clarify` tool to batch these questions — see step 2.
  Observed failure on this deployment: `Tool clarify returned error:
  "questions must be an array of question objects."` A plain chat message
  works every time and matches this skill's own "single message" design.
- Don't invent answers for missing information and proceed anyway; an
  under-specified agent is the exact failure mode this skill exists to
  prevent.
- A well-specified initial request should result in zero or one follow-up
  question, not the full list — re-read what was already said before asking.

## Verification

Before handing off, read the spec back once: does every line have a real
answer (not a placeholder), and would a stranger reading only this spec
build the same agent the user is picturing? If not, ask again rather than
guessing.
