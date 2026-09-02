#!/usr/bin/env bash
# Runs llama-server natively (Metal), bound to 127.0.0.1 so that only the
# hermes container (via host.docker.internal) and this machine can reach it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
MODEL_FILE="${MODEL_FILE:-qwen2.5-coder-7b-instruct-q4_k_m.gguf}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-65536}"
LLAMA_PORT="${LLAMA_PORT:-8080}"

MODEL_PATH="$(pwd)/models/${MODEL_FILE}"
if [ ! -f "${MODEL_PATH}" ]; then
  echo "Model not found: ${MODEL_PATH}" >&2
  echo "Run ./scripts/download-model.sh first" >&2
  exit 1
fi

LLAMA_SERVER_BIN="$(./scripts/find-or-build-llama-server.sh)"
echo "==> Binary : ${LLAMA_SERVER_BIN}"
echo "==> Model  : ${MODEL_PATH}"
echo "==> Context: ${LLAMA_CTX_SIZE} tokens — port ${LLAMA_PORT}"

exec "${LLAMA_SERVER_BIN}" \
  -m "${MODEL_PATH}" \
  --host 127.0.0.1 \
  --port "${LLAMA_PORT}" \
  -c "${LLAMA_CTX_SIZE}" \
  -ngl 99 \
  --jinja
