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

echo "==> Running inference benchmark (padded-prompt prefill + generation) — this can take a while on CPU-only hardware, that's the point"
python3 - "$LLAMA_URL" "$MODEL" "$PROMPT_SIZE_JSON" <<'PY'
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
