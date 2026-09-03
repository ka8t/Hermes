# Hardware sizing: check what you actually have

This deployment's documented performance numbers (prefill time, tokens/
second — see `shared/model-notes.md`, `shared/telegram-setup.md`) were
measured on specific hardware. They don't automatically apply to yours.
This page is about checking what you're actually running on before
trusting them.

**Status: partial.** CPU thread sizing is auto-detected on one path today
(below). GPU detection and native-path/macOS thread verification are not
yet built — see "What's not covered yet."

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

`linux-x86_64-vps/provision.sh` (Docker path) runs `nproc` on first `.env`
creation and sets `LLAMA_THREADS` to `nproc - 1` (leaving one core for the
OS/Docker/Hermes overhead), overriding `.env.example`'s conservative
default of `2` — see the script's own comments for the exact logic.

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
| CPU/thread auto-detection on the native (no-Docker) VPS path | #12 |
| GPU detection and support for the Linux VPS path (this repo assumes CPU-only unconditionally today) | #13 |
| Verifying whether CPU thread count matters at all on macOS given full Metal offload (currently assumed, not measured) | #14 |
| A mandatory real-throughput benchmark during provisioning (this page covers manual spec-checking; an automated pass/fail gate is separate) | #27 |

## Sources

- This repo's own live incident (commits 032302b, and the model-notes.md
  agentic-drift entry) — not a third-party source, direct observation.
- `nproc`, `free`, `lscpu`, `nvidia-smi` — standard Linux utilities, see
  their respective man pages.
