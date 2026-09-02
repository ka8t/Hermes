#!/usr/bin/env bash
# Lance llama-server en natif (Metal), lié à 127.0.0.1 pour que seul le
# conteneur hermes (via host.docker.internal) et cette machine y accèdent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
MODEL_FILE="${MODEL_FILE:-qwen2.5-coder-7b-instruct-q4_k_m.gguf}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-65536}"
LLAMA_PORT="${LLAMA_PORT:-8080}"

MODEL_PATH="$(pwd)/models/${MODEL_FILE}"
if [ ! -f "${MODEL_PATH}" ]; then
  echo "Modèle introuvable : ${MODEL_PATH}" >&2
  echo "Lancez d'abord : ./scripts/download-model.sh" >&2
  exit 1
fi

LLAMA_SERVER_BIN="$(./scripts/find-or-build-llama-server.sh)"
echo "==> Binaire : ${LLAMA_SERVER_BIN}"
echo "==> Modèle  : ${MODEL_PATH}"
echo "==> Contexte: ${LLAMA_CTX_SIZE} tokens — port ${LLAMA_PORT}"

exec "${LLAMA_SERVER_BIN}" \
  -m "${MODEL_PATH}" \
  --host 127.0.0.1 \
  --port "${LLAMA_PORT}" \
  -c "${LLAMA_CTX_SIZE}" \
  -ngl 99 \
  --jinja
