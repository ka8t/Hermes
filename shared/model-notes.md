# Choosing a GGUF model for llama.cpp

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
