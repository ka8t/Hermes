---
name: build-agent-from-intent
description: Turn a clarified agent spec (from clarify-agent-intent, or a named template) into a working, verified Hermes profile — without the user touching a config file by hand.
version: 1.0.0
author: ka8t/Hermes
license: MIT
metadata:
  hermes:
    tags: [profiles, onboarding, agent-creation]
    related_skills: [clarify-agent-intent]
---

# Build Agent From Intent

Implements issue https://github.com/ka8t/Hermes/issues/3 — the second half
of the guided agent creation flow. Only run this once a spec exists (either
handed off by `clarify-agent-intent`, or a named template from `../templates/`
with no open questions).

## When to Use

Immediately after `clarify-agent-intent` produces a complete spec, or when
the user names one of the templates in `../templates/` and confirms they
want it as-is.

## Never guess

If any part of the spec is missing or ambiguous, hand back to
`clarify-agent-intent` instead of filling the gap with an assumption. This
skill only executes a spec that is already complete.

## Procedure

1. **Create the profile**:
   ```
   hermes profile create <name>
   ```
   `<name>` is a short, lowercase, hyphenated slug derived from the spec's
   `Agent:` line (e.g. "Content Watcher" → `content-watcher`).

2. **Apply a template, if named in the spec** — copy the persona/skill
   material from `../templates/<template-name>/` into the new profile
   before doing anything else, so later steps build on top of it rather
   than a blank profile.

3. **Model**: if the spec's `Model:` line names something other than the
   deployment default, check whether that model ID already exists among
   the models this deployment can actually serve. If the deployment is one
   of the ka8t/Hermes reference configurations, that list lives in a
   `models.yaml` managed via llama-swap — add a new entry there rather than
   inventing a model ID nothing serves. If unsure what's available or how
   models are managed on this particular host, ask rather than guess.

4. **Channel**: if the spec's `Channel:` line names a gateway, configure it
   for this profile (`hermes -p <name> gateway setup`, or the equivalent
   for the requested platform). If `Channel: none`, skip this step
   entirely — don't wire up a gateway nobody asked for.

5. **Schedule**: if the spec's `Schedule:` line names a cadence, create the
   cron job for this profile:
   ```
   hermes -p <name> cron create "<the agent's recurring task, in plain language>"
   ```
   If `Schedule: on-demand`, skip this step.

6. **Verify**, don't just assume it worked:
   - Confirm the profile exists (`hermes profile` listing includes it).
   - If a channel was configured, confirm the gateway reports connected,
     not just "configured."
   - If a cron job was created, confirm it appears in the profile's
     scheduled jobs with the expected cadence.

## Output

A recap sent back to the user, in this shape (mirrors the "everything's
operational" summary style from the tutorial this repo's docs were built
from — a checklist, not prose):

```
Profile "<name>" — ready
- Persona: <template used, or "custom">
- Model: <model id>
- Channel: <configured/connected, or "none — chat-only">
- Schedule: <cadence, or "none — on-demand only">
```

## Pitfalls

- Don't silently reuse an existing profile name — if `hermes profile
  create <name>` reports it already exists, ask the user whether they meant
  to modify that one instead of creating a new one.
- Wiring a channel or cron job the spec didn't ask for is exactly the
  under-specification failure this whole flow exists to avoid — only do
  what the spec says.
- This skill never deletes or overwrites another profile's files. If
  something in the target profile's directory already exists and doesn't
  look like a fresh `hermes profile create` output, stop and ask the user
  before touching it. This deployment's approval policy already backs this
  up (`approvals.mode: manual` — a destructive or overwriting action always
  requires an explicit human answer), but don't rely on that as the only
  safeguard: ask first regardless.

## Verification

The recap above **is** the verification step — every line must reflect
something actually checked in step 6, not the intended configuration. If a
check fails (e.g. gateway not connected), say so plainly instead of
reporting success.
