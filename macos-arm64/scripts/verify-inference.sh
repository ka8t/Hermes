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

# Hermes runs either in Docker or natively on this platform (see README's
# comparison table) — detect which, same check as build-agent-template.sh
# uses on the VPS side, and call `hermes prompt-size` the matching way.
if [ -n "$(docker compose ps hermes --status running --quiet 2>/dev/null)" ]; then
  HERMES_PROMPT_SIZE_CMD=(docker compose exec -T hermes hermes prompt-size --json --platform telegram)
elif command -v hermes >/dev/null 2>&1; then
  HERMES_PROMPT_SIZE_CMD=(hermes prompt-size --json --platform telegram)
else
  echo "!! Neither a running 'hermes' Docker container nor a native 'hermes' binary found." >&2
  echo "!! Start Hermes first (see README.md), then re-run this check." >&2
  exit 1
fi

echo "==> Checking llama-swap is reachable at ${LLAMA_URL}"
if ! curl -sf "${LLAMA_URL}/health" >/dev/null; then
  echo "!! ${LLAMA_URL}/health not reachable. Is llama-swap running natively (see README.md)?" >&2
  exit 1
fi

# Real fixed prompt size for this exact deployment, and (on the Docker
# path) the only reliable place to read the active model ID from the host:
# `data/config.yaml` is bind-mounted and written by the container as its
# own UID (0700), unreadable by the host user running this script even
# though the file exists — confirmed live on the VPS variant of this
# script, same container image, same bug class. Don't assume a bind mount
# is host-readable just because it exists.
PROMPT_SIZE_JSON="$("${HERMES_PROMPT_SIZE_CMD[@]}" 2>/dev/null || echo '')"
if [ -z "$PROMPT_SIZE_JSON" ]; then
  echo "!! 'hermes prompt-size' failed — is Hermes actually running?" >&2
  exit 1
fi

echo "==> Running inference benchmark (padded-prompt prefill + generation)"
python3 - "$LLAMA_URL" "$PROMPT_SIZE_JSON" <<'PY'
import json, sys, time, urllib.request

llama_url, prompt_size_raw = sys.argv[1], sys.argv[2]
model = json.loads(prompt_size_raw)["model"]

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
