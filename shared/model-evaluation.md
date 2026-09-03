# Model and configuration evaluation (issues #28-#32)

**Status: specced, not yet implemented.** This page documents the
design an admin will be able to reproduce once #29-#31 are built — the
commands below are the intended shape, verified against the official
tools' own docs, but no wrapper script or results database exists in
this repo yet. Written before implementation, per this repo's
specs → issues → documentation → implementation workflow.

Two independent tools, two independent questions:

| Question | Tool | Issue |
|---|---|---|
| Does this model call tools reliably? | [BFCL](https://gorilla.cs.berkeley.edu/leaderboard.html) (Berkeley Function-Calling Leaderboard) | #29 |
| Is this hardware/config fast enough? | `llama-bench` (bundled with llama.cpp) | #30 |

Both feed a re-evaluation trigger (#31) and are meant to be reproducible
by any admin on their own hardware (#28's "done when").

## Model evaluation: BFCL (#29)

**Open question from #28, now resolved** (verified against BFCL's own
docs at
[github.com/ShishirPatil/gorilla](https://github.com/ShishirPatil/gorilla),
not assumed): BFCL does not require vLLM. Its `--skip-server-setup` flag
bypasses BFCL's own vLLM/SGLang server-management phase and generates
responses against a server you already have running — llama-swap
qualifies, since it exposes the same OpenAI-compatible
`/v1/chat/completions` shape BFCL expects.

```bash
# .env for bfcl-eval:
LOCAL_SERVER_ENDPOINT=127.0.0.1   # or the VPS's llama-swap host
LOCAL_SERVER_PORT=8080

bfcl generate \
  --model meta-llama/Llama-3.1-8B-Instruct-FC \
  --test-category simple,parallel,multi_turn \
  --skip-server-setup
```

**The real constraint isn't the endpoint, it's the model handler.** BFCL
doesn't accept an arbitrary `--model` string — each model needs a
registered handler (prompt formatting + response parsing) listed in
BFCL's own `SUPPORTED_MODELS.md`. This repo's default model is already
covered — `meta-llama/Llama-3.1-{8B,70B}-Instruct-FC` (function-calling
mode, the one that matters here) and the plain `-Instruct` (prompt mode)
are both listed as supported, self-hosted models. **Any other candidate
model added to the "broad list" this issue calls for must already have a
BFCL handler, or someone has to write one** (a real contribution —
implement a handler class, register it in `model_config.py` — not a
config change). This bounds the realistic candidate list; it isn't
"every model this repo could theoretically run."

Test categories, per #29's proposal: at minimum simple function calling,
parallel calls, and multi-turn — the three categories that matter for
this repo's actual usage pattern (single tool calls, and the guided
agent-creation flow's multi-step skill invocations, see
[`skills/agent-creation/`](../skills/agent-creation/)).

**Distinguishing failure types** (#29's own acceptance criteria): a
model can fail a BFCL category two different ways that need different
fixes —
- a **parser problem**: the model's output is fine but llama.cpp's
  chat-format parser for that family mis-handles it (the `peg-native`
  bug class already documented in `shared/model-notes.md`) — fixable by
  a llama.cpp update or a different quantization/build, not by switching
  models.
- a **model-quality problem**: the model genuinely picks the wrong tool
  or malforms arguments regardless of parser correctness (the
  Python-repr-string bug documented in `shared/model-notes.md`'s
  goal-drift section, issue #37) — fixable only by using a different
  model.

BFCL's own category breakdown (which specific calls failed and how) is
the tool for telling these apart; don't collapse a failing run into a
single pass/fail number.

## Hardware/config evaluation: llama-bench (#30)

**Verified against llama.cpp's own `tools/llama-bench` docs**, not
assumed: `llama-bench` already does almost everything #30 asks for
without any wrapper needed for the sweep itself —

```bash
llama-server --version   # confirms which llama-bench ships alongside it
                          # (bundled together, see shared/prebuilt-binaries.md)

llama-bench \
  -m models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf \
  -t 1,2,4,8 \
  -ngl 0,99 \
  -o sql > results.sql
sqlite3 results.db < results.sql
```

- `-t/--threads` and `-ngl/--n-gpu-layers` both accept comma-separated
  lists — llama-bench runs the full cartesian sweep itself, no wrapper
  loop needed.
- `-o sql` outputs directly importable SQL, creating (or appending to) a
  `llama_bench` table with ~40 columns — including hardware
  identification (`cpu_info`, `gpu_info`, `backends`) alongside the
  measured throughput (`avg_ts`, `stddev_ts`) and the exact config used
  (`n_threads`, `n_gpu_layers`, `n_batch`, ...). **This means #30's
  "internal results database" doesn't need a custom schema at all** —
  `llama-bench`'s own SQL output, appended to one SQLite file across
  runs and machines, already gives comparable rows with enough metadata
  to explain an anomalous result (this repo's own 8-vCPU
  under-utilization incident, see `shared/hardware-sizing.md`, is
  exactly the kind of thing `cpu_info` + `n_threads` together makes
  visible instead of hiding in a one-off log).
- Context-size sweeping doesn't have a dedicated flag the way
  threads/GPU-layers do; `-d/--n-depth` (prefill the KV cache to a given
  depth before testing) and `-p/--n-prompt` / `-n/--n-gen` (prompt and
  generation lengths per test) are llama-bench's actual levers here —
  the sweep granularity #30 wants is achieved by varying these, not a
  `--ctx-size` sweep flag (llama-bench doesn't have one).

This shares its underlying `llama-bench` invocation with #27's mandatory
per-deployment benchmark (`scripts/verify-inference.sh`) — that script
does a simpler, single-config check with a raw HTTP request against
llama-swap (since it measures the actual serving path, prompt included);
this issue is the broader, standalone multi-config comparison tool,
run directly against `llama-bench`/`llama-server` rather than through
llama-swap. Keep the shared reasoning (why a given threshold or
observation matters) referenced between the two rather than duplicated,
per #30's own text.

## Continuous re-evaluation (#31)

Not yet scoped in detail — depends on #29 and #30 existing first (per
#31's own text: "nothing to trigger otherwise"). The open design
question from #31 stays open: whether "continuous" means on every
`models.yaml` change (a GitHub Actions workflow, this repo already has
`ci.yml`/`publish-image.yml` to follow the same conventions) or
periodically against the live deployment's real hardware (a scheduled
job on the deployment machine) — or both, for the two different
questions (#29 is candidate-model comparison, doesn't need the live
deployment; #30's per-deployment benchmark does).

## What this page is not

This is not a benchmark results archive — no actual BFCL or llama-bench
run has happened yet for this repo's model list. It's the reproducible
recipe an admin (or a future implementation of #29-#31) will follow.
Real numbers belong in #30's results database once it exists, not in
this doc.

## Sources

- BFCL / `bfcl-eval` — official repository and docs:
  [github.com/ShishirPatil/gorilla](https://github.com/ShishirPatil/gorilla)
  (`--skip-server-setup`, `LOCAL_SERVER_ENDPOINT`/`LOCAL_SERVER_PORT`,
  `SUPPORTED_MODELS.md`'s Llama-3.1-Instruct-FC entries — all fetched and
  read directly, not summarized from memory).
- BFCL leaderboard / methodology (ICML 2025):
  [gorilla.cs.berkeley.edu/leaderboard.html](https://gorilla.cs.berkeley.edu/leaderboard.html),
  [paper](https://proceedings.mlr.press/v267/patil25a.html).
- `llama-bench` — official docs:
  [github.com/ggml-org/llama.cpp/tree/master/tools/llama-bench](https://github.com/ggml-org/llama.cpp/tree/master/tools/llama-bench)
  (`-o sql`, `-t`, `-ngl`, `-d`, `-p`, `-n` flags — fetched and read
  directly).
- This repo's own `shared/model-notes.md` (parser-vs-model-quality
  failure examples) and `shared/hardware-sizing.md` (the under-utilization
  incident #30's schema design references).
