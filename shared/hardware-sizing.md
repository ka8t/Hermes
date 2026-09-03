# Hardware sizing: check what you actually have

This deployment's documented performance numbers (prefill time, tokens/
second — see `shared/model-notes.md`, `shared/telegram-setup.md`) were
measured on specific hardware. They don't automatically apply to yours.
This page is about checking what you're actually running on before
trusting them.

**Status: partial.** CPU thread sizing is auto-detected on one path today,
and a mandatory real-inference benchmark now runs after first boot (both
below). GPU detection and native-path/macOS thread verification are not
yet built — see "What's not covered yet."

## Mandatory: verify real inference throughput (issue #27)

Detecting hardware specs (vCPU count, GPU presence) is not enough — this
repo's own incident below shows two boxes with identical specs can have
very different real throughput. After `docker compose up -d` (or starting
the native services) and confirming llama-swap is healthy, run:

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

## What's auto-detected today

`linux-x86_64-vps/provision.sh` (Docker path) and
`linux-x86_64-vps/scripts/run-llama-swap-native.sh` (native path, issue
#12) both run `nproc` on first `.env` creation and set `LLAMA_THREADS` to
`nproc - 1` (leaving one core for the OS/Docker/Hermes overhead),
overriding `.env.example`'s conservative default of `2` — see either
script's own comments for the exact logic. The native path's fix is
code-reviewed and lint-passed but not live-tested against a real
from-scratch native VPS in this session (the reference VPS runs the
Docker path).

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

## What's not covered yet

| Gap | Tracking issue |
|---|---|
| GPU detection and support for the Linux VPS path (this repo assumes CPU-only unconditionally today) | #13 |
| Verifying whether CPU thread count matters at all on macOS given full Metal offload (currently assumed, not measured) | #14 |

## Sources

- This repo's own live incident (commits 032302b, and the model-notes.md
  agentic-drift entry) — not a third-party source, direct observation.
- `nproc`, `free`, `lscpu`, `nvidia-smi` — standard Linux utilities, see
  their respective man pages.
