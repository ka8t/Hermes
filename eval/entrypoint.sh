#!/usr/bin/env bash
# Runs inside the hermes-eval-bfcl image (see Dockerfile) — the proxy and
# both bfcl-eval phases, driven by env vars set by run-bfcl.sh's `docker run`.
set -euo pipefail

: "${UPSTREAM_HOST:?}" "${UPSTREAM_PORT:?}" "${REAL_MODEL_ID:?}" "${MODEL:?}" "${CATEGORIES:?}"

# BFCL's local-inference handler hard-codes the "model" field it sends to
# either --local-model-path's filesystem path or its own internal handler
# name — never llama-swap's real model ID, and there's no BFCL flag to
# override this (confirmed directly in base_oss_handler.py). This proxy
# rewrites it before forwarding to the real llama-swap endpoint. See
# model_alias_proxy.py and ../shared/model-evaluation.md.
python3 model_alias_proxy.py \
  --listen-port 8091 \
  --upstream-host "${UPSTREAM_HOST}" \
  --upstream-port "${UPSTREAM_PORT}" \
  --real-model-id "${REAL_MODEL_ID}" &
PROXY_PID=$!
trap 'kill "${PROXY_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:8091/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# BFCL loads its own .env with python-dotenv(override=True), which
# silently overwrites any exported env vars with whatever bfcl-eval's own
# .env.example template hard-codes — editing the file directly is the
# only thing that works. Confirmed live 2026-09-03 against bfcl-eval
# 2026.3.23: VLLM_ENDPOINT/VLLM_PORT (this repo's earlier finding, itself
# already a correction of an even earlier wrong guess) no longer exist at
# all — base_oss_handler.py now reads LOCAL_SERVER_ENDPOINT/
# LOCAL_SERVER_PORT, or REMOTE_OPENAI_BASE_URL directly if set. Without
# either being set correctly, spin_up_local_server()'s readiness loop
# polls the unset default (localhost:1053) forever — a real, silent hang,
# not a crash (confirmed via py-spy: stuck sleeping in a `requests.get`
# retry loop with zero requests ever reaching the proxy). Setting
# REMOTE_OPENAI_BASE_URL straight to the proxy's own /v1 is simpler than
# reconstructing LOCAL_SERVER_ENDPOINT/PORT. See
# ../shared/model-evaluation.md.
grep -v '^#\?\s*REMOTE_OPENAI_BASE_URL=' /workspace/.env > /workspace/.env.tmp || true
echo "REMOTE_OPENAI_BASE_URL=http://127.0.0.1:8091/v1" >> /workspace/.env.tmp
mv /workspace/.env.tmp /workspace/.env

export BFCL_PROJECT_ROOT=/workspace
TOKENIZER_DIR="/workspace/tokenizers/meta-llama-3.1-8b-instruct"

echo "==> Generating responses: model=${MODEL} categories=${CATEGORIES} (via proxy -> ${REAL_MODEL_ID})"
bfcl generate \
  --model "${MODEL}" \
  --test-category "${CATEGORIES}" \
  --skip-server-setup \
  --local-model-path "${TOKENIZER_DIR}" \
  --allow-overwrite

echo "==> Scoring responses"
bfcl evaluate \
  --model "${MODEL}" \
  --test-category "${CATEGORIES}"
