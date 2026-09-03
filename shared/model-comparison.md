# In-channel multi-model comparison: `/compare` (issue #39)

**Status: specced, not yet implemented.** This page documents the design
reached in a grilling session (2026-09-03) — the commands and config
shown below are the intended shape, not something you can run yet.
Written before implementation, per this repo's specs → issues →
documentation → implementation → tests workflow. See
[issue #39](https://github.com/ka8t/Hermes/issues/39) for the full spec
and acceptance criteria.

## What this is (and isn't)

Send one question from a channel (Telegram) and get answers from several
models to that same question, side by side. Two things this is
deliberately **not**:

- **Not `/model <name>`** (Hermes's own command) — that switches the
  session's active model one at a time, sequentially, no side-by-side
  comparison. `/compare` is for comparing; `/model` is for choosing.
- **Not BFCL/`llama-bench`** ([`model-evaluation.md`](model-evaluation.md),
  issues #28-#32) — that's automated, large-scale, offline, scored
  evaluation across many prompts. `/compare` is a manual, one-off,
  in-channel spot-check for a single question. Use `/compare` to quickly
  eyeball how a couple of models handle one real request; use the BFCL
  harness to decide which model to adopt as the default.

## Usage (once implemented)

```
/compare What's today's date and can you check my calendar for conflicts?
/compare llama-3.1-8b-instruct,qwen2.5-coder-7b What's today's date and can you check my calendar for conflicts?
```

- No model list: compares against every model currently listed in
  `models.yaml`.
- A comma-separated model list right after `/compare`: compares only
  those models (IDs must match `models.yaml` exactly).

Each model's answer arrives as its own separate message, as soon as
that model finishes — not one combined message at the end. On the
sequential path (see below), you'll see one message per model arrive
one at a time; on the parallel path, they can arrive close together.

Every compared model answers with **no shared conversation history** —
each one sees only your `/compare` question, nothing before it. This is
a deliberate fairness choice: no model gets to "cheat" off context
another one doesn't have.

Every compared model runs as **this deployment's actual configured
Hermes agent** — its real system prompt, tools, and skills — not a bare
completion request. That's the point: this project cares how a model
uses the real tools (see the goal-drift finding in
`shared/model-notes.md`, issue #37), and a raw-completion comparison
wouldn't show that at all.

## Execution: sequential by default, parallel only if you configure it

By default, `/compare` runs models **one at a time** — each one fully
loads, answers, and unloads before the next starts. This works on any
deployment, no extra configuration needed, but means real wait time: on
a CPU-only VPS, each model can take several minutes just for the first
token (see [`hardware-sizing.md`](hardware-sizing.md)). Before starting
a sequential run, you'll get a message estimating the total wait —
informational, not a confirmation prompt; the comparison starts either
way.

**Parallel execution is possible, but it's something you configure, not
something `/compare` figures out on its own.** llama-swap (the reverse
proxy this repo already runs in front of llama.cpp — see
[`managing-models.md`](managing-models.md)) supports a `groups` setting
that lets specific models stay loaded simultaneously instead of evicting
each other:

```yaml
# In data/models.yaml (VPS) or models.yaml (macOS), alongside your
# existing `models:` block:
groups:
  "compare-fast":
    swap: false        # false = all members can run together, no swapping
    exclusive: false   # false = this group doesn't unload other groups
    members:
      - "llama-3.1-8b-instruct"
      - "qwen2.5-coder-7b-instruct"
```

`/compare` checks whether the **exact set** of models you asked to
compare matches a configured group with `swap: false`. If it does, it
runs them in parallel. If it doesn't — no matching group, or only some
of the requested models are grouped — it falls back to **fully
sequential**, never a mix of both in the same run. This is deliberate:
`/compare` never estimates your available RAM/VRAM itself and never
edits `models.yaml` on your behalf. A wrong memory estimate means an
out-of-memory crash, not a graceful fallback — so that decision stays
yours, sized to hardware you actually know the specs of.

**Before configuring a parallel group**: make sure your machine actually
has enough RAM (or VRAM, on a GPU setup — see
[`gpu-setup.md`](gpu-setup.md)) to hold every member model
simultaneously, on top of whatever else is running. There's no
enforcement here beyond what llama-swap itself does; an under-sized
group will manifest as an out-of-memory error or thrashing, not a clean
error message.

## Safety: why `terminal`, `code_execution`, and `delegation` are excluded

This section explains a mandatory, non-optional part of the design, not
an option to turn off.

`/compare` is planned to work by invoking `hermes -z --model <id>
"<question>"` once per compared model (`-z`/`--oneshot`: Hermes's
one-shot CLI mode, real tools/skills, no session file). **`hermes -z`
unconditionally bypasses every dangerous-command approval check, by
design** — confirmed directly against the installed CLI's own `--help`
text and corrected in [`enterprise-safety.md`](enterprise-safety.md)
after a live test found it (issue #38). If a `/compare` question ever
prompted a model to attempt something destructive, every compared model
would run it immediately, with zero human approval, since `-z` doesn't
ask.

The mitigation decided for this feature: every `hermes -z --model <id>`
invocation `/compare` launches passes `-t/--toolsets` with `terminal`,
`code_execution`, and `delegation` excluded — regardless of what
toolsets are normally enabled for interactive sessions on this
deployment. This is a **technical** restriction baked into how
`/compare` invokes Hermes, not a documented rule asking you to only ask
safe questions — a rule like that gets forgotten or bypassed, a toolset
that isn't there can't be misused. It's in addition to, not instead of,
this repo's existing `disabled_toolsets` (`browser-use`, `tts`,
`vision` — see `config.yaml.example`).

**Practical effect**: a model being compared can still reason about
wanting to run a command or delegate a task — you'll see that in its
response — it just can't actually execute it, no matter which model
you're comparing or what you asked.

## Sources

- llama-swap `groups` configuration (official docs, exact YAML
  confirmed): [github.com/mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
  and its `docs/config.example.yaml`.
- `hermes -z`/`--oneshot` and `hermes send` — this deployment's own
  installed `hermes --help` output (see `enterprise-safety.md` for the
  approval-bypass finding, and the official CLI reference:
  [hermes-agent.nousresearch.com/docs/reference/cli-commands](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)).
- This repo's own `shared/hardware-sizing.md` (per-model timing used for
  the wait-time estimate) and `shared/model-notes.md` (the goal-drift
  finding motivating "full agent, not raw completion").
