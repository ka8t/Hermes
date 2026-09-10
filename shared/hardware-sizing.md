# Hardware sizing: check what you actually have

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

This deployment's documented performance numbers (prefill time, tokens/
second — see `shared/model-notes.md`, `shared/telegram-setup.md`) were
measured on specific hardware. They don't automatically apply to yours.
This page is about checking what you're actually running on before
trusting them.

**Status: complete.** CPU thread sizing is auto-detected on every path,
GPU support exists for the Linux VPS path (all vendors), macOS thread
count has been empirically settled, and a mandatory real-inference
benchmark runs after first boot on both platforms — see "What's covered
now" below for exactly what's live vs. still awaiting a real-hardware
report from an operator.

## Mandatory: verify real inference throughput (issue #27)

Detecting hardware specs (vCPU count, GPU presence) is not enough — this
repo's own incident below shows two boxes with identical specs can have
very different real throughput. After `docker compose up -d` (or starting
the native macOS services) and confirming llama-swap is healthy, run:

```bash
# Linux VPS
./scripts/verify-inference.sh

# macOS
./scripts/verify-inference.sh
```

This sends two real requests to the running llama-swap/llama-server —
a padded ~2500-token prompt (measures prefill throughput) and a short
generation request (measures tokens/second) — reads this deployment's
actual fixed prompt budget via `hermes prompt-size --json` (system
prompt + skills index + memory + user profile + tool schemas, not a
guess), and estimates real first-reply latency:

```
estimated_prefill_seconds = (real_prompt_chars / 4.3) / measured_prefill_tok_per_s
```

**The 4.3 chars/token figure is empirically calibrated**, not assumed:
measured by tokenizing this repo's own `clarify-agent-intent/SKILL.md`
content (4495 chars → 1041 tokens) through the deployed model's own
tokenizer, via llama-swap's `/upstream/<model>/tokenize` route — real
repo content, not a generic ratio pulled from nowhere. It's an
approximation (JSON tool schemas tokenize somewhat differently from
prose), good enough for a pass/warn/fail gate, not exact.

**Thresholds** (informed by this repo's own testing, not arbitrary):

| Estimated first-reply latency | Verdict | Meaning |
|---|---|---|
| < 300s (5 min) | PASS | Comfortable |
| 300-1200s (5-20 min) | WARN | Usable, but slow — consider `disabled_toolsets`, a smaller model, or investigating contention (see the incident below) |
| > 1200s (20 min) | FAIL | Investigate before deploying to real users — check threads, contention, and model in that order (see below) |

Confirmed live on this repo's own VPS, 2026-09-03 (8 vCPUs, `LLAMA_THREADS=8`,
no contention): 22.3 tok/s prefill, 7.4 tok/s generation, ~10,942-token real
prompt budget, ~491s estimated first-reply latency — **WARN**, not PASS,
even on a correctly-configured, uncontended box. This is the actual,
current, honest number for the default reference VPS spec — not a
best-case claim.

## Check what you actually have

```bash
nproc              # logical CPU count
free -h            # total/available RAM
lscpu | grep -i "model name"   # CPU generation — older/budget virtualized
                                # CPUs can underperform even at the same
                                # core count (see the incident below)
nvidia-smi         # GPU presence (if applicable) — "command not found"
                    # means no NVIDIA GPU/driver
```

## RAM and disk headroom (issue #72)

`verify-inference.sh` (both platforms) also checks available RAM and disk
space alongside the throughput benchmark, using real measured numbers —
not guesses — for this repo's *default* config (Llama-3.1-8B-Instruct,
65536-token context, q8_0 KV cache quantization, already the default on
both platforms):

| | Measured footprint | FAIL below | WARN below | PASS |
|---|---|---|---|---|
| RAM (macOS, M1) | ~9GB RSS | 9GB | 11GB | ≥11GB |
| RAM (VPS, Debian 8vCPU CPU-only) | ~12GB RSS | 12GB | 14GB | ≥14GB |
| Disk (both) | ~8.5-9.7GB (model + image[s]) | 10GB | 20GB | ≥20GB |

These thresholds are calibrated for the default model/context — changing
either invalidates them. Uses `awk` for the arithmetic/comparisons, not
`bc`: found live, 2026-09-07, that a fresh Debian VPS doesn't have `bc`
installed by default. Also forces `LC_ALL=C` for this section: on a
machine using a comma-decimal locale (e.g. `fr_FR`), `awk`'s `printf`
silently emits comma-decimals ("26,2"), breaking every comparison that
reads the number back.

## What's auto-detected today

`linux-x86_64-vps/provision.sh` (the only VPS path, Docker) and
`macos-arm64/scripts/run-llama-swap-native.sh` (native macOS path, issue
#12) both run `nproc`/`sysctl` on first `.env` creation and set
`LLAMA_THREADS` accordingly (leaving one core for the OS/Docker/Hermes
overhead), overriding `.env.example`'s conservative default of `2` — see
either script's own comments for the exact logic.

A native (no-Docker) VPS path existed briefly (2026-09-07) and had its own
copy of this auto-detection logic, but was abandoned before any real
deployment used it — see `docs/adr/0001-vps-docker-only.md`. The VPS is
Docker-only now.

## The incident this doc exists because of

Confirmed live, 2026-09-03, on this repo's own VPS: the box has **8
vCPUs and 22 GB RAM**, but `LLAMA_THREADS` was left at `.env.example`'s
default of `2` for an entire testing session — nobody had adjusted it,
and nothing detected the mismatch. Every "20-40 minute cold prefill"
measurement recorded elsewhere in this repo's docs from that period
reflects a process using a quarter of the box's real CPU capacity, not a
hardware ceiling.

After correcting to `LLAMA_THREADS=8` (all cores) on a machine additionally
freed of unrelated background load (several unrelated Docker
containers and services sharing the same VPS were consuming a sustained
~7.5 load average out of 8 cores — see the VPS's own investigation
in this session's history), a single inference request still took over
an hour in one case. Reconstructing the session from `state.db` showed
this was **not** a hardware ceiling either — it was a model reliability
problem (see `shared/model-notes.md`'s agentic-goal-drift finding).
Untangling "is this slow because of hardware, contention, or the model"
took real, sequential investigation — checking `nproc`/`load average`
first, then `llama-server`'s own `/slots` endpoint for real token
throughput, then the actual session transcript — rather than assuming
any single cause.

**Takeaway**: a "slow response" can have at least three independent
causes (under-provisioned thread count, other processes competing for
the same CPU, or the model itself struggling with the task) — check them
in that order, don't assume the first hypothesis is the right one.

## Follow-up incident: a stuck generation outlives the client that gave up on it (2026-09-10)

Confirmed live on this repo's own VPS, 2026-09-10 — a different failure
shape from the 2026-09-03 incident above, caught while investigating a
Telegram message that got no reply after 55+ minutes.

**What the logs showed:**

- `docker compose ps`: both containers healthy, no crash.
- `docker compose exec llama-swap ps aux`: `llama-server` at **~710% CPU,
  continuously, since the request started** — confirmed genuinely active
  (not hung/idle) by sampling its cumulative CPU time twice, 9s apart:
  +64s of CPU time in 9s wall time, consistent with ~7 of 8 cores busy the
  whole way through.
- hermes's own client-side log, after exactly 3600s: `Stream stale for
  3600s (threshold 3600s) — no chunks received. ... Killing connection.`
  followed immediately by `Stream drop on attempt 2/3 — retrying.` — zero
  bytes, zero chunks reached the client in a full hour, even though the
  server was demonstrably computing the whole time.
- `docker compose logs llama-swap`: the same request eventually surfaced
  there too — `<llama-3.1-8b-instruct> recovered from upstream
  disconnection during streaming`, `error processing streaming response:
  no valid JSON data found in stream`, and a completed access log line
  timed at `59m59.712805491s`. The stream itself broke somewhere between
  `llama-server` and the client; the 3600s figure is hermes's own watchdog
  threshold, not proof the underlying request would ever have finished
  naturally.

**Why the context was this large in the first place:** queried directly
from `state.db` (not assumed) — the Telegram session behind this message
was opened 2026-09-03, a week earlier, not a fresh session: 81 accumulated
messages, 32 tool calls, 17 enabled tools (each with a JSON schema resent
on every turn), for a total prompt of ~17,488 tokens. The session's
`compression_fallback_streak`/`compression_ineffective_count` were both
0 — automatic context compaction had never triggered, because it's gated
on how full the 65536-token context window is (~27% here), not on how
slow that many tokens actually are to process on CPU-only hardware. A
context that's "not full" by the model's own limit can still be a very
expensive one to prefill every single turn on this hardware.

**Root cause of the hang itself:** `linux-x86_64-vps/config/models.yaml`'s
`llama-server` command has no `-n`/`--predict` cap on generation length,
and llama.cpp doesn't reliably treat a client-side disconnect as a
cancellation signal. hermes's own 3600s watchdog protects the *client*
from waiting forever, but does nothing server-side — the original
generation can keep running as a "zombie" after hermes has already given
up on it, and any retry queues up behind that same never-finishing
request instead of getting a fresh attempt.

**Immediate fix applied:** `docker compose restart llama-swap` — cleanly
killed the stuck `llama-server` process and started a fresh one (confirmed
by PID change and the CPU-time-delta check above showing active work on a
request that started seconds after the restart, not minutes of
accumulated backlog). No data loss — this container holds no state of its
own. The retried request then completed normally.

**Structural fix applied the same day:** `--predict 4096` added to
`llama-server`'s command in both platforms'
`config/models.yaml.example` (and the live `data/models.yaml` on this
VPS and the local Mac deployment). llama-server's own default is `-1`
(unbounded) — this caps any single completion to at most 4096 generated
tokens (~9 minutes worst case at this VPS's measured 7.4 tok/s, well
under 3 minutes on the Mac's 25-36 tok/s), instead of letting a
runaway/repetition-loop generation run indefinitely toward the
65536-token context ceiling. Doesn't fix the underlying
"client-disconnect doesn't cancel server-side generation" gap (that's
llama.cpp's own behavior, not something this repo's config controls),
but bounds its blast radius to a known, small maximum instead of open-
ended.

`silent-failure-watchdog.sh`'s own detection margin was widened
alongside this (`STALE_MARGIN_MULTIPLIER` 2 → 3, both platforms) — it
was computing its silence threshold as `local_stream_stale_timeout × 2`
while its own comment already documented that hermes can legitimately
take 3 full retries before giving up; confirmed live this same incident
that a single attempt really can consume the entire timeout, not just
"some of it," so the 2x margin could have fired a false "something went
wrong" notification mid-legitimate-retry.

**Mitigation available today, not yet automated:** hermes has a built-in
`/compress` slash command (alias `/compact`), usable directly in any
conversation including over Telegram — `/compact` summarizes older turns,
`/compact here N` keeps the last N verbatim, `/compact --preview` shows
the effect first. Running it periodically on a long-lived channel session
(like a Telegram DM that's been open for a week) keeps the per-turn
prompt small regardless of the 65536-token ceiling. Not wired into
`silent-failure-watchdog.sh` or any auto-trigger yet — currently a manual
step an operator has to remember to run.

**Takeaway**: this repo's context-compaction trigger is sized relative to
the model's context window, not to this hardware's actual throughput —
the two can disagree badly on a CPU-only box. A long-lived gateway
session (weeks of accumulated history) is a slow-response risk even well
under the context ceiling, independent of the goal-drift/hardware/
contention causes already covered above.

## What's covered now

All of #11's original sub-issues are resolved:

- CPU thread auto-detection: VPS (Docker) and macOS (Docker + native) (#12).
- GPU support for the Linux VPS path, all three vendors (#13) — see
  [`gpu-setup.md`](gpu-setup.md); implemented but not live-verified, no
  matching hardware available to test against.
- macOS CPU thread count confirmed empirically **not to matter** once
  Metal does full offload (#14) — live-tested on a real M1 Mac, see
  `shared/model-notes.md`'s "macOS CPU thread count" section for the
  actual numbers.
- The mandatory real-throughput benchmark (#27,
  `scripts/verify-inference.sh`) — live-tested on both a CPU-only VPS
  and a real M1 Mac.

Nothing is left unimplemented from the original hardware-sizing scope.

## Reducing memory: KV cache quantization, not a smaller model (issue #52)

At this repo's required 64k context (see `shared/model-notes.md`), the KV
cache — not the model weights — dominates `llama-server`'s memory
footprint, and its size is set by architecture (`num_hidden_layers ×
num_key_value_heads × head_dim`), not total parameter count. Checked
directly against real model configs before assuming otherwise: Qwen3-8B
(36 layers) and even Qwen3-4B (also 36 layers, identical KV
configuration to Qwen3-8B) both have a *larger* KV cache than this
repo's default Llama-3.1-8B-Instruct (32 layers) — switching to a
smaller model would not meaningfully reduce memory here, and could make
it worse.

The real lever, confirmed live on this Mac (M1, Metal): `llama-server`'s
`-ctk`/`-ctv` flags (KV cache quantization, default `f16`) plus
`--flash-attn on` (required for quantized KV cache). Set to `q8_0`:
RSS dropped from ~14-15GB to **~9GB** at the same 65536-token context,
same model, same speed (25-36 tokens/sec either way — no measurable
slowdown), tool-calling verified unaffected (raw curl test plus the
full `eval/regression-goal-drift.sh` through the real Hermes stack).
Already the default on both platforms:
`macos-arm64/config/models.yaml.example` (Metal, above) and
`linux-x86_64-vps/config/models.yaml.example`. **Confirmed live on the
production VPS too (2026-09-04, Debian, 8 vCPU, CPU-only inference)**:
RSS dropped from ~15.8GB to **~12GB** at the same 65536-token context,
same speed (~6.2-6.6 tokens/sec either way — this deployment's
CPU-bound baseline, unrelated to this change), tool-calling verified
correct. So the memory win holds on both the Metal and CPU paths, even
though the underlying quantized-KV-cache kernel implementation differs
between them — worth knowing rather than assuming from one platform to
the other, but in this case it transfers cleanly.

**A debugging trap worth knowing about, hit live while measuring this**:
a `pkill` that's supposed to stop `llama-swap`/`llama-server` before
changing `-ctk`/`-ctv` and restarting can fail silently — the new
process then fails to bind its port ("address already in use", visible
only in its own log, not surfaced as an error to whoever ran the
restart) while the *old*, stale process keeps answering requests with
whatever config it was already running. This produced a wildly wrong
first reading here (0.07-0.15 tokens/sec, looking like a catastrophic
regression) before being caught by explicitly confirming the process
PID changed and the port was genuinely free before re-testing. Any
"it got much slower after this config change" finding on this repo's
llama-server should rule this out first — check the actual serving
PID, don't trust that a restart command succeeded just because it
returned.

## Sources

- This repo's own live incident (commits 032302b, and the model-notes.md
  agentic-drift entry) — not a third-party source, direct observation.
- `nproc`, `free`, `lscpu`, `nvidia-smi` — standard Linux utilities, see
  their respective man pages.
- `-ctk`/`-ctv`/`--flash-attn` flags and their allowed values — fetched
  directly from this repo's own built `llama-server --help` output, not
  assumed. Model architecture values (`num_hidden_layers`,
  `num_key_value_heads`, `head_dim`) for Llama-3.1-8B-Instruct, Qwen3-8B,
  and Qwen3-4B — fetched directly from each model's own `config.json` on
  Hugging Face, not assumed from parameter count alone.
