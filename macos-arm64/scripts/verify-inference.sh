#!/usr/bin/env bash
# Mandatory post-provisioning check (issue #27): measures REAL inference
# throughput against this exact running deployment, instead of only
# detecting hardware specs — see #14 (macOS CPU-thread sizing, still open;
# this check is independent of that and covers Metal-offload throughput
# directly). Run once llama-swap is up (`./scripts/run-llama-swap.sh` or the
# launchd service) and Hermes is running (Docker or native) — see
# ../../shared/hardware-sizing.md for why spec detection alone isn't enough
# and for the exact thresholds/calibration used below.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8080}"

echo "==> Checking llama-swap is reachable at ${LLAMA_URL}"
if ! curl -sf "${LLAMA_URL}/health" >/dev/null; then
  echo "!! ${LLAMA_URL}/health not reachable. Is llama-swap running natively (see README.md)?" >&2
  exit 1
fi

# The model ID comes from llama-swap itself (/v1/models) — this only
# requires llama-swap to be up, not Hermes. Bug found live-testing this
# script on 2026-09-03: it previously required Hermes to be running just
# to read the model ID out of `hermes prompt-size`'s JSON, which meant the
# whole throughput benchmark (which needs nothing from Hermes) refused to
# run without Hermes installed/started first — an unnecessary coupling.
MODEL="$(curl -sf "${LLAMA_URL}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
if [ -z "$MODEL" ]; then
  echo "!! Could not read a model ID from ${LLAMA_URL}/v1/models." >&2
  exit 1
fi

# Real fixed prompt size for this exact deployment — used only for the
# latency ESTIMATE in step 3 below, not for the throughput measurement
# itself. Hermes runs either in Docker or natively on this platform (see
# README's comparison table); if neither is up, this degrades gracefully
# to "unknown" (see the Python heredoc) rather than refusing to run the
# actual benchmark.
if [ -n "$(docker compose ps hermes --status running --quiet 2>/dev/null)" ]; then
  PROMPT_SIZE_JSON="$(docker compose exec -T hermes hermes prompt-size --json --platform telegram 2>/dev/null || echo '')"
elif command -v hermes >/dev/null 2>&1; then
  PROMPT_SIZE_JSON="$(hermes prompt-size --json --platform telegram 2>/dev/null || echo '')"
else
  echo "==> Hermes not running (Docker or native) — skipping the real-prompt-size estimate,"
  echo "    throughput numbers below are still real and valid."
  PROMPT_SIZE_JSON=""
fi

# --- RAM/disk headroom (issue #72) — real measured numbers, not guesses:
# the default deployment (Llama-3.1-8B-Instruct, 65536-token context, q8_0
# KV cache quantization — already this platform's default) measured ~9GB
# RSS on a real M1 Mac (see ../../shared/hardware-sizing.md's #52 section).
# These thresholds only apply to that default config — a different model
# or context size invalidates them.
echo "==> Checking RAM and disk headroom"
# awk only, no bc: found live testing the VPS variant of this check,
# 2026-09-07 — a fresh Debian install doesn't have bc installed by
# default, and awk already handles floating-point arithmetic/comparisons
# natively (macOS does ship bc, but using the same awk-only approach on
# both platforms avoids two implementations of the same logic). Also
# forced LC_ALL=C: on a machine using a comma-decimal locale (e.g.
# fr_FR), awk's printf silently emits comma-decimals ("26,2" instead of
# "26.2"), which then fails as invalid syntax wherever that number is
# compared again.
export LC_ALL=C
PAGE_SIZE="$(sysctl -n hw.pagesize)"
TOTAL_RAM_BYTES="$(sysctl -n hw.memsize)"
FREE_PAGES="$(vm_stat | awk '/^Pages free:/ {gsub("\\.", "", $3); print $3}')"
INACTIVE_PAGES="$(vm_stat | awk '/^Pages inactive:/ {gsub("\\.", "", $3); print $3}')"
AVAILABLE_RAM_GB="$(awk -v f="${FREE_PAGES:-0}" -v i="${INACTIVE_PAGES:-0}" -v p="${PAGE_SIZE}" 'BEGIN{printf "%.1f", (f+i)*p/1073741824}')"
TOTAL_RAM_GB="$(awk -v b="${TOTAL_RAM_BYTES}" 'BEGIN{printf "%.1f", b/1073741824}')"
DISK_AVAIL_GB="$(df -k . | awk 'NR==2 {printf "%.1f", $4/1048576}')"

echo "    RAM:  ${AVAILABLE_RAM_GB}GB available / ${TOTAL_RAM_GB}GB total"
echo "    Disk: ${DISK_AVAIL_GB}GB available"

RAM_OK=1
if awk -v v="${AVAILABLE_RAM_GB}" 'BEGIN{exit !(v<9)}'; then
  echo "    FAIL: below the ~9GB this default config actually needs — expect"
  echo "          swapping/OOM, not just slowness."
  RAM_OK=0
elif awk -v v="${AVAILABLE_RAM_GB}" 'BEGIN{exit !(v<11)}'; then
  echo "    WARN: close to the ~9GB measured footprint — little headroom for"
  echo "          anything else running on this Mac."
else
  echo "    PASS: comfortable headroom above the ~9GB measured footprint."
fi

if awk -v v="${DISK_AVAIL_GB}" 'BEGIN{exit !(v<10)}'; then
  echo "    FAIL: below ~10GB — the default model alone is ~4.6GB and the"
  echo "          Hermes Docker image is ~3.9GB; you'll run out mid-setup."
  RAM_OK=0
elif awk -v v="${DISK_AVAIL_GB}" 'BEGIN{exit !(v<20)}'; then
  echo "    WARN: usable, but little room for a second model or Docker"
  echo "          image/log growth."
else
  echo "    PASS: comfortable disk headroom."
fi
echo ""

echo "==> Running inference benchmark (padded-prompt prefill + generation)"
LATENCY_OK=1
python3 - "$LLAMA_URL" "$MODEL" "$PROMPT_SIZE_JSON" <<'PY' || LATENCY_OK=0
import json, sys, time, urllib.request

llama_url, model, prompt_size_raw = sys.argv[1], sys.argv[2], sys.argv[3]

def chat(payload, timeout):
    req = urllib.request.Request(
        f"{llama_url}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.load(resp)
    return body, time.time() - start

# --- 1. Prompt-processing (prefill) throughput ---
filler = "The quick brown fox jumps over the lazy dog. " * 250
pp_body, pp_time = chat(
    {"model": model, "messages": [{"role": "user", "content": filler}], "max_tokens": 1},
    timeout=600,
)
pp_tokens = pp_body["usage"]["prompt_tokens"]
pp_tok_s = pp_tokens / pp_time

# --- 2. Generation throughput ---
tg_body, tg_time = chat(
    {
        "model": model,
        "messages": [{"role": "user", "content": "Count from 1 to 100, one number per line."}],
        "max_tokens": 100,
    },
    timeout=120,
)
tg_tokens = tg_body["usage"]["completion_tokens"]
tg_tok_s = tg_tokens / tg_time

print()
print("== Inference benchmark results ==")
print(f"Prompt processing: {pp_tok_s:.1f} tok/s (measured on a {pp_tokens}-token prompt, {pp_time:.1f}s)")
print(f"Generation:        {tg_tok_s:.1f} tok/s (measured over {tg_tokens} generated tokens, {tg_time:.1f}s)")

# --- 3. Estimate real first-reply latency — see the VPS script/
#        shared/hardware-sizing.md for the 4.3 chars/token calibration.
try:
    ps = json.loads(prompt_size_raw) if prompt_size_raw.strip() else {}
    total_chars = (
        ps.get("system_prompt", {}).get("chars", 0)
        + ps.get("skills_index", {}).get("chars", 0)
        + ps.get("memory", {}).get("chars", 0)
        + ps.get("user_profile", {}).get("chars", 0)
        + ps.get("tools", {}).get("json_bytes", 0)
    )
except (json.JSONDecodeError, AttributeError):
    total_chars = 0

if total_chars:
    est_tokens = round(total_chars / 4.3)
    est_prefill_s = est_tokens / pp_tok_s
    print(f"This deployment's real fixed prompt budget: ~{est_tokens} tokens ('hermes prompt-size')")
    print(f"Estimated first-reply prefill time: ~{est_prefill_s:.0f}s")
    print()
    # Same thresholds as the VPS check — Metal offload should comfortably
    # PASS in practice; a FAIL here on a Mac is worth investigating (e.g.
    # accidentally running llama-server CPU-only, see shared/model-notes.md).
    if est_prefill_s < 300:
        print("PASS: estimated first-reply latency is comfortable.")
        sys.exit(0)
    elif est_prefill_s < 1200:
        print("WARN: estimated first-reply latency is slow (5-20 min). Usable, but see")
        print("      shared/hardware-sizing.md before pointing this at real users.")
        sys.exit(0)
    else:
        print("FAIL: estimated first-reply latency exceeds 20 minutes.")
        print("      Unexpected on Metal — confirm llama-server actually used -ngl 99")
        print("      (see shared/model-notes.md) before proceeding.")
        sys.exit(1)
else:
    print()
    print("WARN: could not compute a latency estimate ('hermes prompt-size' unavailable).")
    print("      Throughput numbers above are still valid; verify manually.")
    sys.exit(0)
PY

if [ "${RAM_OK}" = "0" ] || [ "${LATENCY_OK}" = "0" ]; then
  exit 1
fi
exit 0
