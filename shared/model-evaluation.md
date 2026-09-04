# Model and configuration evaluation (issues #28-#32)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

**Status: #29's BFCL path is implemented and partially live-verified;
#30/#31 are still specced only.** Written before implementation per this
repo's specs → issues → documentation → implementation → tests
workflow — this section was updated after live-testing surfaced several
real corrections to the original design (wrong env var names, missing
dependencies, and a genuine model-routing incompatibility with
llama-swap). See `eval/setup-bfcl.sh`, `eval/run-bfcl.sh`, and
`eval/model_alias_proxy.py`.

**Honest test status (2026-09-04)**: a full local run (this MacBook Pro
M1, Metal-accelerated llama-server via llama-swap) was started for
`simple_python`, `parallel`, and `multi_turn` (1400 cases combined) and
run for ~7.5 hours before being deliberately stopped by the user — the
multi-turn categories are slow enough (each test case is a multi-step
conversation, several sequential model calls; a single llama-server
instance handling them one at a time, no batching) that completing all
of them would have taken an estimated 20+ hours, and the machine was
under load from other work at the same time. Two categories finished
completely before the stop and were scored for real:

| Category | Cases | Accuracy |
|---|---|---|
| `simple_python` | 400/400 | **54.75%** |
| `parallel` | 200/200 | **52.50%** |

These are real, complete BFCL v4 scores for this model
(`Llama-3.1-8B-Instruct-FC`, Q4_K_M) on this hardware — not partial or
estimated. The `multi_turn` categories were stopped mid-run
(`multi_turn_base`: 191/200 generated; `multi_turn_long_context`: 52/200;
`multi_turn_miss_func`/`multi_turn_miss_param`: not started) and were
**not** scored — an incomplete multi-turn run isn't a fair or meaningful
percentage, so none is reported rather than a misleading one. `bfcl
evaluate`'s own overall/leaderboard accuracy figure (visible in
`eval/bfcl-workspace/score/data_overall.csv`) is **not** used here for
the same reason: it weights every BFCL category including the untested
ones (live, multi_turn, web_search, memory), which count as 0% and drag
the composite figure down to a meaningless 1.77% — the two per-category
numbers above are the real signal.

Completing the `multi_turn` categories (and the VPS leg, per this repo's
local-then-remote testing order) is a possible future re-run, not a
blocker on anything currently — `simple_python` and `parallel` already
give real signal on single- and parallel-call tool-calling reliability,
this repo's most common usage pattern. Re-running
(`cd eval && ./run-bfcl.sh 127.0.0.1 8080`) reuses the exact same,
already-fixed pipeline.

Two independent tools, two independent questions:

| Question | Tool | Issue |
|---|---|---|
| Does this model call tools reliably? | [BFCL](https://gorilla.cs.berkeley.edu/leaderboard.html) (Berkeley Function-Calling Leaderboard) | #29 |
| Is this hardware/config fast enough? | `llama-bench` (bundled with llama.cpp) | #30 |

Both feed a re-evaluation trigger (#31) and are meant to be reproducible
by any admin on their own hardware (#28's "done when").

## Model evaluation: BFCL (#29)

**Open question from #28, resolved**: BFCL does not require vLLM. Its
`--skip-server-setup` flag bypasses BFCL's own vLLM/SGLang
server-management phase and generates responses against a server you
already have running — llama-swap qualifies.

```bash
cd eval
./setup-bfcl.sh                    # once: builds the Docker image, downloads tokenizer files
./run-bfcl.sh 127.0.0.1 8080       # <llama-swap host> <llama-swap port>
```

Everything — the venv, `bfcl-eval`, `soundfile`, `transformers` — installs
inside a Docker image (`eval/Dockerfile`), never on the host. Only the
small, human-readable bits (downloaded tokenizer JSON files, BFCL's own
`.env`, generated results/scores) live on disk, under `eval/bfcl-workspace/`
— everything runs from inside this repo's own `eval/` folder, no host
setup beyond Docker itself, no directory outside the repo. See #51 for
why this shape was required.

Six real problems were found live-testing this, none documented
upstream, all now handled by the scripts/`Dockerfile` above — worth
knowing if you're debugging this yourself:

0. **iCloud Drive eviction of a venv (macOS only) — why this is
   containerized at all.** On this Mac, with iCloud Drive's "Optimize Mac
   Storage" enabled (`defaults read com.apple.bird optimize-storage` →
   `1`) — a setting this repo's own folder must stay under, since the
   repo itself needs to stay fully synced, with nothing relocated outside
   it (#51) — a venv's thousands of small package files, if created
   directly under `eval/` on the host, can get evicted to save local
   space and then fail to re-hydrate: confirmed live 2026-09-03, `import
   transformers` failed with `TimeoutError: [Errno 60] Operation timed
   out`, reproduced with a plain `wc -l` on the same file (not a Python or
   bfcl-eval bug). An earlier fix moved the venv to
   `~/.cache/hermes-eval`, outside the repo — rejected (#51): the repo
   must run entirely from its own folder, with no relocated install
   directories and no host configuration changes. Containerizing the
   install (`eval/Dockerfile`) resolves both: the thousands of small
   package files live inside the image's own filesystem, which iCloud
   never sees at all, while `eval/`'s own files (scripts, `Dockerfile`,
   the small downloaded tokenizer/`.env`/results files in
   `eval/bfcl-workspace/`) stay in place, tiny, and fully synced.

1. **Missing dependencies.** `pip install bfcl-eval` alone doesn't run:
   its Qwen support imports `soundfile` at module load time (crashes on
   startup for every model, not just Qwen), and its local-inference path
   imports `transformers` directly without declaring it as a dependency
   — only bfcl-eval's own `oss-eval-vllm` extra pulls it in, and that
   extra also drags in the full `vllm==0.8.5` package (GPU-oriented,
   unused here since `--skip-server-setup` means vllm never serves
   anything). `eval/Dockerfile` installs `soundfile` and `transformers`
   directly instead.
2. **Env var names keep moving upstream — pin the mechanism, not the
   names.** At different points this session, `bfcl-eval` has read three
   different env var sets for pointing at an existing OpenAI-compatible
   server: an earlier draft of this doc wrongly guessed
   `LOCAL_SERVER_ENDPOINT`/`LOCAL_SERVER_PORT`; the version installed
   when this was first live-tested actually read
   `VLLM_ENDPOINT`/`VLLM_PORT`; the version now installed (`bfcl-eval`
   2026.3.23) reads `LOCAL_SERVER_ENDPOINT`/`LOCAL_SERVER_PORT` again (the
   name came back, this time for real — confirmed directly in the
   installed `base_oss_handler.py`) — **and** now also supports
   `REMOTE_OPENAI_BASE_URL`, which sets the full base URL directly and
   takes priority when set. Missing this cost a real, silent hang: with
   neither set, `spin_up_local_server()`'s readiness loop polls the
   unset default (`localhost:1053`) forever, sleeping and retrying with
   no error — confirmed via `py-spy dump` on the stuck process, zero
   requests ever reaching the proxy. `eval/entrypoint.sh` now sets
   `REMOTE_OPENAI_BASE_URL` directly to the proxy's own `/v1` — simpler
   than reconstructing endpoint/port separately, and the most direct
   match for "point BFCL at a server I already have running." BFCL loads
   `.env` with `python-dotenv(override=True)`, which silently
   **overwrites** any shell-exported env var with whatever's hard-coded
   in its own `.env.example` template — exporting the var has no effect;
   `eval/entrypoint.sh` edits the `.env` file directly, every run,
   precisely because this keeps moving.
3. **The gated tokenizer.** BFCL's local-inference handler loads the
   model's tokenizer via `transformers.AutoTokenizer`, from the model's
   *original* HuggingFace repo — separate from and in addition to
   llama-swap actually running inference. For Llama 3.1, that original
   repo (`meta-llama/Llama-3.1-8B-Instruct`) is license-gated (requires a
   HuggingFace account and accepting Meta's terms) — this deployment
   doesn't use gated/account-walled sources anywhere else (the GGUF
   itself comes from bartowski's ungated re-upload, see
   `shared/model-notes.md`), so `setup-bfcl.sh` instead downloads just
   the small tokenizer files (not model weights) from
   [`NousResearch/Meta-Llama-3.1-8B-Instruct`](https://huggingface.co/NousResearch/Meta-Llama-3.1-8B-Instruct)
   — confirmed ungated live (`"gated": false`, plain download, no
   token needed; same underlying model/license as the GGUF already used,
   just without HuggingFace's account-gate friction).
4. **Model-name routing mismatch, the big one.** BFCL's local-inference
   handler hard-codes the `"model"` field it sends in every request to
   either `--local-model-path`'s filesystem path or its own internal
   handler name (`meta-llama/Llama-3.1-8B-Instruct-FC`) — confirmed
   directly in `base_oss_handler.py`'s `_query_prompting`
   (`model=self.model_path_or_id`), no BFCL flag overrides this. Neither
   value matches llama-swap's real model ID (`llama-3.1-8b-instruct`),
   so llama-swap rejects every request with `"no router for requested
   model"`. `eval/model_alias_proxy.py` sits between BFCL and llama-swap
   specifically to fix this: it rewrites the `"model"` field to the real
   ID (read from llama-swap's own `/v1/models`, not hard-coded) before
   forwarding — `run-bfcl.sh` starts it automatically, no manual config
   needed.
5. **Concurrency mismatch.** BFCL's local-inference path always fires up
   to 100 concurrent requests (`ThreadPoolExecutor(max_workers=100)`,
   hard-coded, not affected by any BFCL flag) — correct for a real vLLM
   server's continuous batching, wrong for a single llama-server instance
   serving one model, which returned `429 Too many requests` for nearly
   every request beyond the first. `model_alias_proxy.py` serializes
   inference requests with a lock rather than changing the actual
   deployment's llama-server concurrency flags — keeps eval traffic from
   affecting production serving behavior.

**The real remaining constraint isn't the endpoint, it's the model handler.** BFCL
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
[`skills/agent-creation/`](../skills/agent-creation/)). **Category name
changed upstream, 2026-09-03**: `bfcl-eval` 2026.3.23 no longer has a
bare `simple` category — it split into `simple_python`/`simple_java`/
`simple_javascript` (confirmed directly against the installed package's
`bfcl_eval.constants.category_mapping.ALL_CATEGORIES`). `simple_python`
(400 entries) is this repo's default — same intent as the old `simple`,
just the language-specific successor name. `run-bfcl.sh`'s default is
`simple_python,parallel,multi_turn`.

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

### This repo's own regression case (#37)

Separate from BFCL's own datasets: `eval/regression-goal-drift.sh` runs
this repo's own real, previously-observed failure — the exact prompt
"Create an agent that watches a subreddit for AI news and messages me
when something important comes up" — against a running local Hermes
container, and checks whether the model's first tool call is a
project-specific skill (correct) or `delegate_task` (the documented
goal-drift failure, see `shared/model-notes.md`'s #37 section). Unlike
BFCL's own categories, this checks something BFCL's generic datasets
can't: whether a candidate model correctly prefers *this repo's own*
skills over a superficially-similar generic built-in tool. Not
deterministic for the default model — 6 back-to-back runs (2026-09-04)
split 4 `FAIL` (`delegate_task`) / 2 `PASS` (`skill_view`), ordinary LLM
sampling variance rather than a 100%-reproducible bug. Run it several
times and read the failure rate, not a single pass/fail — see
`shared/model-notes.md`'s #37 section.

### This repo's own regression case (#48)

`eval/regression-hallucinated-success.sh` runs the same prompt but lets
the full session play out (not just the first tool call), then checks
whether the model's final message honestly reports any real tool-call
failures instead of narrating them as successes — see
`shared/model-notes.md`'s #48 section. Reproduced cleanly on
2026-09-04: 7/7 `skill_manage` calls failed, final message claimed the
skill was "created," "updated," "loaded," and ready to use. A single
run here is similarly not statistically conclusive (same caveat as
#37) — but this is the *second* independent reproduction of the
pattern (a different failing tool than the original #46 observation),
which strengthens rather than weakens the finding: it's the general
behavior, not a fluke tied to one specific tool.

```bash
cd eval && ./regression-goal-drift.sh
```

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

This is not a benchmark results archive — two complete, real BFCL
category scores (`simple_python`, `parallel`, see above) are the only
real data points so far, the `multi_turn` categories were stopped
incomplete and unscored, and `llama-bench` hasn't been run at all for
this repo's model list. This page is the
reproducible recipe an admin (or a future implementation of #30-#31)
will follow. Real, complete numbers belong in #30's results database
once it exists, not in
this doc.

## Sources

- BFCL / `bfcl-eval` — official repository and docs:
  [github.com/ShishirPatil/gorilla](https://github.com/ShishirPatil/gorilla)
  (`--skip-server-setup`, `SUPPORTED_MODELS.md`'s Llama-3.1-Instruct-FC
  entries). `VLLM_ENDPOINT`/`VLLM_PORT` and the model-routing/concurrency
  behavior above are confirmed directly from the installed package's own
  source (`bfcl_eval/model_handler/local_inference/base_oss_handler.py`),
  not the docs — the docs don't cover this level of detail and, on the
  env var names, were actively wrong.
- `NousResearch/Meta-Llama-3.1-8B-Instruct` — confirmed ungated live via
  the HuggingFace API (`"gated": false`) and a plain unauthenticated
  download (`200 OK`), same day.
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
