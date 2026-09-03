# Choosing a GGUF model for llama.cpp

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

## Table of contents

- [Non-negotiable constraint: context size](#non-negotiable-constraint-context-size)
- [The flag that makes tools actually work: `--jinja`](#the-flag-that-makes-tools-actually-work---jinja)
- [Default model used here](#default-model-used-here)
- [macOS CPU thread count](#macos-cpu-thread-count-confirmed-not-to-matter-with-full-metal-offload-14)
- [Two models this repo tried and rejected](#two-models-this-repo-tried-and-rejected-and-why-read-before-changing-the-default)
- [Known limitation: peg-native format parse failures](#known-limitation-intermittent-peg-native-format-parse-failures)
- [Known limitation: malformed nested tool-call arguments](#known-limitation-malformed-nested-tool-call-arguments-beyond-clarify)
- [Going further](#going-further)

## Non-negotiable constraint: context size

Hermes needs at least a **64,000-token** context window to work properly
(memory, tool list, and history are all sent on every call). Below that,
Hermes either refuses to start or degrades badly. Both configurations in this
repository therefore launch `llama-server` with `-c 65536` (or the equivalent
`LLAMA_CTX_SIZE`).

## The flag that makes tools actually work: `--jinja`

Without `--jinja`, `llama-server` ignores the `tools` parameter sent by
Hermes: tool calls come back as raw JSON text in the reply instead of being
executed. `--jinja` is enabled by default in current `llama-server` builds,
and both `docker-compose.yml` files / scripts in this repository pass it
explicitly anyway. **This flag alone is not sufficient** — see below.

## Default model used here

**Meta-Llama-3.1-8B-Instruct** (`Q4_K_M` quantization, ~4.7 GB) — chosen
after two other candidates failed a real, live tool-calling test (see
below). llama.cpp's `llama3_json` tool-call parser for this model family is
mature and produces a correctly structured OpenAI-style `tool_calls`
response, verified directly (not assumed) against this exact build.

- GGUF repository: https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF
- File used by the scripts: `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`

> If Hugging Face has renamed the file since, open the page above and adjust
> `MODEL_FILE` in `.env` accordingly — the scripts don't invent any other
> filename than this one.

## macOS CPU thread count: confirmed not to matter with full Metal offload (#14)

**Verified live, 2026-09-03, on a MacBook Pro M1 (8 cores: 6P+2E)**: with
`-ngl 99` (full GPU offload, this repo's default on macOS — see
`macos-arm64/config/models.yaml.example`), explicit `--threads` makes no
measurable difference to either prefill or generation throughput.

Three back-to-back runs of `scripts/verify-inference.sh`, same model, same
padded ~2500-token prompt, only `--threads` changed between runs:

| `--threads` | Prompt processing | Generation |
|---|---|---|
| (unset — llama.cpp's own default) | 177.4 tok/s | 23.2 tok/s |
| `2` | 177.6 tok/s | 23.1 tok/s |
| `6` (all performance cores) | 177.5 tok/s | 23.0 tok/s |

Effectively identical across all three — within measurement noise. (An
initial cold-start run before these three read 136.8 tok/s prefill; that
was Metal shader compilation on first load, not a threading effect —
reproduced 177.x tok/s on every run afterward, `--threads` set or not.)

**Conclusion**: don't bother setting `--threads` on the macOS path — the
current default (`macos-arm64/config/models.yaml.example` omits it
entirely) is correct as-is. This is the opposite of the CPU-only VPS path
(see `shared/hardware-sizing.md`), where thread count is the dominant
factor — the difference is `-ngl 99` offloading every layer to the GPU
here, leaving the CPU with negligible work regardless of how many threads
it's allowed to use.

## Two models this repo tried and rejected, and why (read before changing the default)

This repo's default model changed three times during initial testing. Both
rejections were confirmed with a direct, reproducible test — not assumed —
so a future change of mind should be checked the same way before shipping.

### Nous Research's own "Hermes" models — wrong tool entirely

Easy mistake to make: Nous Research ships two different products under the
same name — the **Hermes 2/3/4 model family** (an LLM) and **Hermes Agent**
(the harness this repo deploys, also by Nous Research). They are not the
same thing, and the model family is not meant to drive the harness.
`Hermes-3-Llama-3.1-8B` was briefly shipped as the default based on that
model's own marketing copy ("trained for agentic tool-calling"), without
checking whether Hermes Agent itself endorsed it. It doesn't — confirmed
directly from Hermes Agent's own interactive session banner:

> ⚠ Nous Research Hermes 3 & 4 models are NOT agentic and are not designed
> for use with Hermes Agent. They lack tool-calling capabilities required
> for agent workflows. Consider using an agentic model (Claude, GPT,
> Gemini, DeepSeek, etc.).

### Qwen2.5-Coder-7B-Instruct — this repo's original default, broken by a known llama.cpp bug

Qwen2.5-Coder-7B-Instruct (this repo's first default) reliably reproduced a
**documented, open llama.cpp bug**: tool calls come back as unstructured
plain text (`content`) instead of a populated `tool_calls` array, even with
`--jinja` on. Verified two ways before concluding this: (1) a real
multi-turn Telegram conversation asking Hermes to create a new agent
returned raw JSON text instead of using any tool or following a skill; (2)
a raw `curl` to `llama-server`'s `/v1/chat/completions` with a minimal
`tools` schema, bypassing Hermes entirely, returned the function call
wrapped in stray angle brackets inside `message.content` rather than
`message.tool_calls`. This matches upstream reports, not a local
misconfiguration:

- [ggml-org/llama.cpp#12279](https://github.com/ggml-org/llama.cpp/issues/12279) — tool call issues specifically on Qwen2.5-Coder-7B-Instruct GGUF
- [openclaw/openclaw#60601](https://github.com/openclaw/openclaw/issues/60601) — "Qwen 2.5 Coder 32B via llama.cpp: tool calls emitted as plain text, not structured tool_calls" (same symptom, larger Qwen2.5 variant)

The same raw `curl` test against Meta-Llama-3.1-8B-Instruct, same machine,
same llama.cpp build, returned a correctly populated `tool_calls` array
(`finish_reason: "tool_calls"`, `function.arguments` as a JSON string) —
confirming the difference is the model family's parser support in
llama.cpp, not this repo's configuration.

**If you're tempted to switch to any Qwen2.5 model for tool-heavy agent
work on llama.cpp, run the raw `curl` test above first.**

## Known limitation: intermittent "peg-native format" parse failures

Observed live in this repo's own VPS testing, 2026-09-03: `openai.APIError:
The model produced output that does not match the expected peg-native
format`, on Meta-Llama-3.1-8B-Instruct, mid-session (not on the first
message). This is **not** the same bug as the Qwen2.5 issue above, and
switching models is not the fix — it's a known, still-open family of bugs
in llama.cpp's own `peg-native` chat-format parser (its newer PEG-grammar
based tool-call/response parser), reproducible across several unrelated
model families:

- [ggml-org/llama.cpp#26381](https://github.com/ggml-org/llama.cpp/issues/26381) — the exact error string above, filed as its own bug report
- [ggml-org/llama.cpp#27279](https://github.com/ggml-org/llama.cpp/issues/27279), [#27733](https://github.com/ggml-org/llama.cpp/issues/27733), [#25986](https://github.com/ggml-org/llama.cpp/issues/25986), [#20260](https://github.com/ggml-org/llama.cpp/issues/20260) — the same parser failing on Qwen3, Gemma4, and DeepSeek-family models under different trigger conditions (long tool-call arguments, trailing think-tags, text before a tool call)
- Some hardening has landed upstream ([#24329](https://github.com/ggml-org/llama.cpp/pull/24329), merged), but the failure class is not resolved as of this repo's llama.cpp build (`0.3.0-dev`, build 10752, commit `b96806d9`)

There is no llama-server flag that avoids this while keeping structured
`tool_calls` output — `--skip-chat-parsing` disables the parser entirely,
but that reproduces the Qwen2.5 symptom above (tool calls back as raw text
in `content`), trading one bug for another.

**In practice, this is intermittent and cheap to retry.** Hermes retries
automatically (`attempt N/3`), and a retry within the same session reuses
llama.cpp's cached prompt prefix — observed `ttfb=1.84s` on a retry, versus
20-40 minutes for the original cold prefill on this VPS's 2 vCPUs. Left
alone, most occurrences resolve within a minute or two on retry; there's
usually no need to interrupt and start over.

## Known limitation: malformed nested tool-call arguments beyond `clarify`

Observed live, 2026-09-03: reconstructed a full `hermes -z` agentic
session from `state.db` after a 69-minute run with no output (see
`shared/telegram-setup.md`'s prefill-time notes for why a single session
can take this long on CPU-only hardware). The transcript showed
Meta-Llama-3.1-8B-Instruct calling `delegate_task` three times in a row
with its `tasks` parameter sent as a plain string instead of a JSON
array (`"tasks must be a JSON array of task objects; received a string
that could not be parsed as JSON"`) — the same category of bug already
documented for the `clarify` tool (see
`skills/agent-creation/clarify-agent-intent/SKILL.md`'s fix), but on a
**different** tool. This model's difficulty with nested array/object tool
parameters is not `clarify`-specific; expect it on any tool with a
similarly-shaped schema, not just the ones already worked around.

**More seriously**: after failing `delegate_task` and briefly succeeding
with `terminal`, the same session went completely off-task — repeatedly
calling `skill_view` against the bundled `github` skill (auth, PR
workflow, API cheatsheet, none of it relevant) and cycling
add/replace/fail/remove/re-add on an unrelated memory entry, twice, for
the rest of the 23-tool-call session — never returning to the original
request ("create an agent that watches a subreddit for AI news"). This
is goal drift on a real multi-step agentic task, not a hardware or
prompt-format issue, and it's exactly the failure mode the model/config
evaluation harness (multi-turn BFCL categories, see the tracking issue
for that work) is meant to catch systematically instead of finding by
accident during manual testing.

**Root-caused, not just observed** (see issue #37 for the full
investigation): the malformed `tasks` argument was specifically
Python-`repr()`-style syntax serialized as a string
(`"[{'goal': '...', ...}"`, single-quoted keys, truncated/unclosed) —
not just "invalid JSON," a model defaulting to Python literal syntax
under a schema asking for a JSON array. `agent.stall_guards` (on by
default) correctly detected the repeated identical failure and told the
model to change strategy — Hermes's own guardrail worked exactly as
designed. The model's "change of strategy" was itself the failure: it
pivoted to `pip install -U prisma` (a database ORM, unrelated to the
task), then wandered into unrelated `github`-skill lookups and memory
edits.

**Verified this is not a prompt/skill-authoring problem before
concluding it's a model limitation**: the recovered system prompt (from
`state.db`'s `system_prompts` table, keyed by the session's
`system_prompt_hash` — `sessions.system_prompt` itself was NULL) showed
`clarify-agent-intent` and `build-agent-from-intent` correctly indexed
under `ka8t-hermes/agent-creation`, with Hermes's own generic
instruction ("load [skills] even for tasks you already know how to do")
present immediately above the skills index. This skill's own "When to
Use" trigger phrase ("create an agent that...") is a near-verbatim match
for the actual test prompt. The model had everything it needed to find
and use the right skill, and didn't — a model capability/judgment
limitation, not something fixable by rewording a skill file or the
system prompt.

**Not yet re-tested against a different model** — this finding is
reason to prioritize that evaluation work before trusting
Meta-Llama-3.1-8B-Instruct with unattended multi-step tasks (cron jobs,
`delegate_task`), even though its single-turn tool-calling (the original
`curl` test above) still checks out. This exact prompt is being added as
a regression case to that evaluation suite (issue #29) rather than left
as an anecdote.

**Real end-to-end Telegram test protocol (issue #46, in progress,
2026-09-03)** — every prior test of this prompt went through `hermes -z`
(one-shot CLI), never a real Telegram round-trip, and #38 already showed
`-z` behaves differently from a real gateway session (no approval gate).
To get a genuine end-to-end reading:

- **Two separate bots**: a Telegram bot's long-polling can only run from
  one place at a time, so local (this Mac) and remote (the VPS) testing
  use two distinct bots — the VPS keeps its existing production bot
  untouched; a second, dedicated bot is created for local testing only.
- **A human sends the message, for real**: Telegram's Bot API can't
  inject a fake incoming message — only a real Telegram client can make
  one arrive at a bot. So this test isn't automatable end-to-end; the
  user sends the exact prompt from their own phone, and verification
  happens server-side afterward (`state.db`, `docker compose logs`),
  the same reconstruction method already used for #37/#38.
- **Two numbers per environment, not one**: real response latency
  (message sent → final reply received, not just raw model tok/s) *and*
  a correctness verdict (clarify-skill invoked vs. drifted) — either one
  alone would be misleading (a fast wrong answer, or a correct answer
  nobody would wait for).
- **GPU-remote variant explicitly out of scope**: no NVIDIA/AMD/Intel GPU
  hardware exists in this environment — same blocking constraint as #13,
  not a new gap. Only local (Metal) and remote-CPU are tested now.
- **Credential safety**: the local test bot's token lives only in the
  local `.env` (git-ignored repo-wide) — never pasted into a commit,
  issue, or log file added to the repo. Checked explicitly before every
  commit made while this test is in progress, not just assumed from
  `.gitignore`.

Results, once available, land here and on issue #37 directly.

**Defense-in-depth, implemented 2026-09-03 (not the fix — model
verification above is)**: `agent.run_budget_seconds: 3600` is now set in
both platforms' `config.yaml.example`. At 80% elapsed (48 min) Hermes
injects a one-time wrap-up notice telling the model to stop new work and
deliver a final answer — bounding a drifting run like this one well
before it reaches the 69-minute mark actually observed, while sitting
above this repo's documented worst-case single cold-prefill response
(~40 min on the CPU-only VPS, see `shared/hardware-sizing.md`) so it
doesn't fire on an ordinary slow response.

## Going further

| Model | When to prefer it |
|---|---|
| Meta-Llama-3.1-8B-Instruct (default) | First try — verified working tool-calling via llama.cpp's `llama3_json` parser, same size class as any 7-8B model |
| Meta-Llama-3.1-70B-Instruct | Dedicated beefy GPU only (vLLM/SGLang, not this repo) |
| DeepSeek-family models | Named directly in Hermes Agent's own compatibility guidance as agentic-capable; llama.cpp has a dedicated `deepseek_v3` tool-call parser — untested by this repo, verify with the raw `curl` test above before adopting |

Source: Hermes official providers documentation —
[hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers),
Hermes Agent's own interactive session output, the bartowski/Meta-Llama-3.1-8B-Instruct-GGUF
model card, and the two llama.cpp/openclaw issues linked above (all
verified 2026-09-03).
