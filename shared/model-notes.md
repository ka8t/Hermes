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
executed. This is the #1 cause of an agent that "replies with JSON" instead
of acting. Both `docker-compose.yml` files / scripts in this repository
already include `--jinja`.

## Default model used here

**Hermes-3-Llama-3.1-8B** (`Q4_K_M` quantization, ~4.9 GB) — Nous Research's
own model, trained specifically for reliable agentic tool-calling, at
essentially the same footprint as a generic 7-8B model.

- Official GGUF repository: https://huggingface.co/NousResearch/Hermes-3-Llama-3.1-8B-GGUF
- File used by the scripts: `Hermes-3-Llama-3.1-8B.Q4_K_M.gguf`

> If Hugging Face has renamed the file since, open the page above and adjust
> `MODEL_FILE` in `.env` accordingly — the scripts don't invent any other
> filename than this one.

### Why not the previous default (Qwen2.5-Coder-7B-Instruct)

This repo shipped Qwen2.5-Coder-7B-Instruct first, on paper a reasonable
generalist choice. A live test of this repo's guided agent-creation skills
(see [`managing-models.md`](managing-models.md) and
[`../skills/agent-creation/`](../skills/agent-creation/)) surfaced a real
failure: asked to create a new agent, it should have followed the
`clarify-agent-intent` skill and asked clarifying questions, but instead
emitted a malformed tool-call attempt as raw text. Hermes-3-Llama-3.1-8B is
Nous Research's own model, trained specifically for reliable function
calling and instruction-following in agentic loops — the exact capability
that failed — at the same size class, so it doesn't cost more RAM/CPU on
either the Mac or the 8 GB VPS this repo targets. Re-tested against the
same prompt after switching — see the commit history for the result.

## Going further

| Model | When to prefer it |
|---|---|
| Hermes-3-Llama-3.1-8B (default) | First try — same size class as any other 7-8B model, tuned for agentic/tool-calling reliability |
| Hermes-4-14B (Nous Research) | Noticeably more capable, but ~9 GB in `Q4_K_M` — doesn't fit the 8 GB VPS this repo targets; fine on a Mac with 32 GB+ RAM |
| Qwen2.5-Coder-32B-Instruct | Apple Silicon Mac with 32 GB+ RAM, code-heavy tasks specifically |
| Llama-3.1-70B-Instruct | Dedicated beefy GPU only (vLLM/SGLang, not this repo) |

Source: Hermes official providers documentation —
[hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers),
the NousResearch/Hermes-3-Llama-3.1-8B-GGUF and bartowski/NousResearch_Hermes-4-14B-GGUF
model cards on Hugging Face (file sizes verified by HTTP HEAD request,
2026-09-03).
