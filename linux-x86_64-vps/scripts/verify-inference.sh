#!/usr/bin/env bash
# Mandatory post-provisioning check (issue #27): measures REAL inference
# throughput against this exact running deployment, instead of only
# detecting hardware specs (vCPU count, GPU presence — see #12/#13).
#
# Run this once `docker compose up -d` is up and `docker compose logs -f
# llama-swap` reports healthy — provisioning is not "done" until this
# passes. See ../../shared/hardware-sizing.md for why spec detection alone
# isn't enough and for the exact thresholds/calibration used below.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8080}"

echo "==> Checking llama-swap is reachable at ${LLAMA_URL}"
if ! curl -sf "${LLAMA_URL}/health" >/dev/null; then
  echo "!! ${LLAMA_URL}/health not reachable. Is 'docker compose up -d' running and healthy?" >&2
  exit 1
fi

# The model ID comes from llama-swap itself (/v1/models) — this only
# requires llama-swap to be up, not the hermes container. Bug found
# live-testing the macOS variant of this script on 2026-09-03: requiring
# Hermes just to read the model ID coupled the whole throughput benchmark
# (which needs nothing from Hermes) to Hermes being up first — unnecessary.
MODEL="$(curl -sf "${LLAMA_URL}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
if [ -z "$MODEL" ]; then
  echo "!! Could not read a model ID from ${LLAMA_URL}/v1/models." >&2
  exit 1
fi

# Real fixed prompt size for this exact deployment (system prompt + skills
# index + memory + user profile + tool schemas) — not a guess, Hermes's own
# accounting — used only for the latency ESTIMATE in step 3 below, not for
# the throughput measurement itself. `data/config.yaml` is bind-mounted and
# written by the container as its own UID (0700), unreadable by the host
# user running this script even though the file exists (confirmed live —
# don't assume host-readable just because it's a bind mount), which is why
# this goes through `hermes prompt-size` and degrades gracefully to
# "unknown" if the container isn't up, rather than reading the file
# directly or refusing to run the benchmark at all.
PROMPT_SIZE_JSON="$(docker compose exec -T hermes hermes prompt-size --json --platform telegram 2>/dev/null || echo '')"
if [ -z "$PROMPT_SIZE_JSON" ]; then
  echo "==> 'hermes prompt-size' unavailable (is the hermes container up?) — skipping the"
  echo "    real-prompt-size estimate, throughput numbers below are still real and valid."
fi

# --- RAM/disk headroom (issue #72) — real measured numbers, not guesses:
# the default deployment (Llama-3.1-8B-Instruct, 65536-token context, q8_0
# KV cache quantization — already this platform's default) measured ~12GB
# RSS on the production reference VPS (Debian, 8 vCPU, CPU-only — see
# ../../shared/hardware-sizing.md's #52 section). These thresholds only
# apply to that default config — a different model or context invalidates
# them.
echo "==> Checking RAM and disk headroom"
# LC_NUMERIC=C: found live testing the macOS variant of this check,
# 2026-09-07 — a locale using ',' as the decimal separator (e.g. fr_FR)
# makes awk/bc emit comma-decimals, which bc then fails to parse back in a
# comparison. Forcing C avoids depending on the operator's locale.
export LC_ALL=C
read -r _ TOTAL_RAM_BYTES _ _ _ AVAILABLE_RAM_BYTES < <(free -b | awk 'NR==2')
AVAILABLE_RAM_GB="$(echo "scale=1; ${AVAILABLE_RAM_BYTES} / 1073741824" | bc)"
TOTAL_RAM_GB="$(echo "scale=1; ${TOTAL_RAM_BYTES} / 1073741824" | bc)"
DISK_AVAIL_GB="$(df -k . | awk 'NR==2 {printf "%.1f", $4/1048576}')"

echo "    RAM:  ${AVAILABLE_RAM_GB}GB available / ${TOTAL_RAM_GB}GB total"
echo "    Disk: ${DISK_AVAIL_GB}GB available"

RAM_OK=1
if (( $(echo "${AVAILABLE_RAM_GB} < 12" | bc -l) )); then
  echo "    FAIL: below the ~12GB this default config actually needs — expect"
  echo "          swapping/OOM, not just slowness."
  RAM_OK=0
elif (( $(echo "${AVAILABLE_RAM_GB} < 14" | bc -l) )); then
  echo "    WARN: close to the ~12GB measured footprint — little headroom for"
  echo "          anything else running on this box."
else
  echo "    PASS: comfortable headroom above the ~12GB measured footprint."
fi

if (( $(echo "${DISK_AVAIL_GB} < 10" | bc -l) )); then
  echo "    FAIL: below ~10GB — the default model alone is ~4.6GB, the Hermes"
  echo "          image ~3.9GB, and llama-swap:cpu ~1.2GB; you'll run out mid-setup."
  RAM_OK=0
elif (( $(echo "${DISK_AVAIL_GB} < 20" | bc -l) )); then
  echo "    WARN: usable, but little room for a second model or Docker"
  echo "          image/log growth."
else
  echo "    PASS: comfortable disk headroom."
fi
echo ""

echo "==> Running inference benchmark (padded-prompt prefill + generation) — this can take a while on CPU-only hardware, that's the point"
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
# A padded ~2000-token prompt with max_tokens=1: wall time is dominated by
# prefill, so prompt_tokens / time approximates real prefill throughput.
filler = "The quick brown fox jumps over the lazy dog. " * 250
pp_body, pp_time = chat(
    {"model": model, "messages": [{"role": "user", "content": filler}], "max_tokens": 1},
    timeout=1800,
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
    timeout=600,
)
tg_tokens = tg_body["usage"]["completion_tokens"]
tg_tok_s = tg_tokens / tg_time

print()
print("== Inference benchmark results ==")
print(f"Prompt processing: {pp_tok_s:.1f} tok/s (measured on a {pp_tokens}-token prompt, {pp_time:.1f}s)")
print(f"Generation:        {tg_tok_s:.1f} tok/s (measured over {tg_tokens} generated tokens, {tg_time:.1f}s)")

# --- 3. Estimate real first-reply latency for THIS deployment's actual
#        prompt size, using an empirically-calibrated chars/token ratio
#        (4.3, measured by tokenizing this repo's own skill-file content
#        through this exact model's tokenizer — see shared/hardware-sizing.md
#        — not a generic guess). Approximate: JSON tool schemas tokenize
#        somewhat differently from prose, but this is far better than
#        assuming any fixed number without measuring.
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
    # Thresholds documented in shared/hardware-sizing.md.
    if est_prefill_s < 300:
        print("PASS: estimated first-reply latency is comfortable.")
        sys.exit(0)
    elif est_prefill_s < 1200:
        print("WARN: estimated first-reply latency is slow (5-20 min). Usable, but see")
        print("      shared/hardware-sizing.md before pointing this at real users.")
        sys.exit(0)
    else:
        print("FAIL: estimated first-reply latency exceeds 20 minutes.")
        print("      Do not consider provisioning complete — see shared/hardware-sizing.md's")
        print("      'check in this order' checklist (threads, contention, model) before proceeding.")
        sys.exit(1)
else:
    print()
    print("WARN: could not compute a latency estimate ('hermes prompt-size' unavailable —")
    print("      is the hermes container up?). Throughput numbers above are still valid;")
    print("      verify the estimate manually once the container is running.")
    sys.exit(0)
PY

if [ "${RAM_OK}" = "0" ] || [ "${LATENCY_OK}" = "0" ]; then
  exit 1
fi
exit 0
