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

**Qwen2.5-Coder-7B-Instruct** (`Q4_K_M` quantization, ~4.7 GB) — a good
size/quality trade-off for agentic use, runs fine on an 8 GB RAM VPS in CPU
mode, and benefits from the Metal GPU on an Apple Silicon Mac.

- Official GGUF repository: https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
- File used by the scripts: `qwen2.5-coder-7b-instruct-q4_k_m.gguf`

> If Hugging Face has renamed the file since, open the page above and adjust
> `MODEL_FILE` in `.env` accordingly — the scripts don't invent any other
> filename than this one.

## Going further

| Model | When to prefer it |
|---|---|
| Qwen2.5-Coder-7B-Instruct (default) | First try, modest VPS, 16 GB Mac |
| Qwen2.5-Coder-32B-Instruct | Apple Silicon Mac with 32 GB+ RAM (much more capable) |
| Hermes-3-Llama-3.1-8B (Nous Research) | Their own model, good perf/size ratio |
| Llama-3.1-70B-Instruct | Dedicated beefy GPU only (vLLM/SGLang, not this repo) |

Source: Hermes official providers documentation —
[hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
and the Qwen model card on Hugging Face.
