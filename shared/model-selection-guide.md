# Model selection guide: matching a model to your hardware

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used
below.

**Status: consolidates existing data, doesn't add new measurements.**
Every number here is already published in [`model-notes.md`](model-notes.md)
or [`model-evaluation.md`](model-evaluation.md) — this page exists because
that data is scattered across incident write-ups, not because any new
testing happened to produce it. See each row's own citation before trusting
a number; don't copy a figure from here into anything else without
re-checking the cited section.

## Quick answer: what to actually run

| Your hardware | Recommended model | Why |
|---|---|---|
| CPU-only VPS or Mac, ≥14GB RAM (VPS) / ≥11GB RAM (Mac) | **Meta-Llama-3.1-8B-Instruct Q4_K_M** (this repo's default) | The only model here with complete, real tool-calling scores (BFCL) and a mature llama.cpp parser. Not the *most* reliable model available anywhere — the most reliable one actually verified to work on this stack. |
| CPU-only, below the RAM thresholds above | Same model, but read [`hardware-sizing.md`](hardware-sizing.md)'s thresholds first — under-provisioned RAM causes swapping/OOM, not just slowness | No smaller *working* alternative is documented here (see "What's not a real option" below) |
| Dedicated GPU with real VRAM headroom (vLLM/SGLang, not this repo's llama-swap path) | Meta-Llama-3.1-70B-Instruct | Never tested on this repo's own stack — this repo only runs llama.cpp/llama-swap, not vLLM/SGLang. Treat as a pointer to a different deployment shape, not a drop-in swap here. |

**If you're tempted to switch away from the default for reliability
reasons**: don't, on today's evidence — the one credible alternative
tested here (Qwen3-8B) is not more reliable, it just fails differently
(see below).

## Full comparison

| Model | Size (Q4_K_M) | RAM footprint | Tool-calling reliability | Status here |
|---|---|---|---|---|
| **Meta-Llama-3.1-8B-Instruct** (default) | ~4.7GB | ~12GB RSS (VPS, 8vCPU) / ~9GB RSS (Mac M1) — [`hardware-sizing.md`](hardware-sizing.md#ram-and-disk-headroom-issue-72) | BFCL `simple_python` **54.75%** (400/400), `parallel` **52.50%** (200/200) — real, complete scores, [`model-evaluation.md`](model-evaluation.md#model-evaluation-bfcl-29). Also has documented goal-drift (#37) and hallucinated-success (#48) failure modes, not unique to this model (see Qwen3-8B below) but the only one with a shipped mitigation (`SOUL.md` instructions) | **In production use, this repo's default** |
| Qwen3-8B | 4.79GB | Not separately measured — same size class, no reason to expect a large delta | No BFCL score run. This repo's own regression tally (4 runs, native Mac): 2 PASS, 2 FAIL — 1 FAIL matches #37's goal-drift pattern, 1 FAIL is #48's hallucinated-success pattern *plus* a new silent-failure mode (#56, zero final message). Detail: [`model-notes.md`](model-notes.md#model-comparison-for-3748s-failure-classes-issue-55-2026-09-04) | Compatible (native `<tool_call>` XML-JSON, correctly parsed) but **not recommended** — not more reliable than the default, just differently unreliable |
| Meta-Llama-3.1-70B-Instruct | N/A here | Needs dedicated GPU hardware (vLLM/SGLang) this repo doesn't provision | No data — never run against this stack | Out of scope for llama-swap/CPU-Metal path; a pointer for a different deployment, not an option in this repo's `provision.sh` |
| DeepSeek-family | N/A here | No data | No data. llama.cpp has a dedicated `deepseek_v3` tool-call parser and Hermes Agent's own docs list DeepSeek as agentic-capable | **Untested by this repo** — verify with the raw `curl` test in `model-notes.md` before adopting anything here |
| Qwen2.5-Coder-7B-Instruct | — | — | Tool calls returned as raw text in `content`, not a populated `tool_calls` array — [ggml-org/llama.cpp#12279](https://github.com/ggml-org/llama.cpp/issues/12279), confirmed live two ways | **Rejected** — this repo's original default, replaced after the bug above |
| Hermes-3-Llama-3.1-8B | — | — | N/A — not an agentic model | **Rejected** — wrong Nous Research product (the chat-model family, not one endorsed for Hermes Agent; the agent's own session banner warns against it) |
| Llama-3-Groq-8B-Tool-Use | — | — | No BFCL handler registered — can't even be scored | **Dropped** before testing |
| watt-ai/watt-tool-8B, Team-ACE/ToolACE-2-8B | — | — | BFCL-scoreable in principle, but use non-OpenAI tool-call conventions (bracketed text / bare JSON blob) incompatible with llama-server's `--jinja` path without a custom template+parser | **Not usable as-is** on this stack |

## What's not a real option (yet)

There is currently **no documented smaller/lighter alternative** for a
genuinely RAM-constrained box below this repo's thresholds — every model
actually verified here is in the same 7-8B parameter class. If your
hardware can't clear [`hardware-sizing.md`](hardware-sizing.md)'s FAIL
threshold, the honest answer today is "this repo hasn't verified a model
that fits," not a specific recommendation.

## Reliability is a moving target, not just this table

Every "tool-calling reliability" figure above is a snapshot, not a
guarantee — this repo's own regression scripts
(`eval/regression-goal-drift.sh`, `eval/regression-hallucinated-success.sh`,
`eval/regression-clarify-array.sh`) exist specifically because sampling
variance means a single run (pass or fail) isn't conclusive on its own —
see `model-notes.md`'s #37 variance finding (6 runs, 4 fail / 2 pass on the
*default* model, same prompt). Re-run the relevant regression script
yourself before trusting a single reported number, on any model, including
the default.

## Sources

- `shared/model-notes.md` — "Two models this repo tried and rejected",
  "Model comparison for #37/#48's failure classes", "Going further"
  sections.
- `shared/model-evaluation.md` — "Honest test status" (BFCL scores),
  "What this page is not" (why no other model has complete scores yet).
- `shared/hardware-sizing.md` — "RAM and disk headroom" table.
- Read directly, 2026-09-10, cross-checked against the sections above
  rather than reconstructed from memory.
