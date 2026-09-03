#!/usr/bin/env bash
# Native (no-Docker) alternative: runs llama-swap + llama-server directly on
# the VPS, no container involved for model serving. See README.md, "Native
# alternative (no Docker at all)".
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
LLAMA_PORT="${LLAMA_PORT:-8080}"
export MODELS_DIR="$(pwd)/models"

if [ ! -f data/models.yaml ]; then
  echo "data/models.yaml not found — copy it from config/models.yaml.example.native first:" >&2
  echo "  mkdir -p data && cp config/models.yaml.example.native data/models.yaml" >&2
  exit 1
fi

if [ -z "${LLAMA_SERVER_BIN:-}" ] || [ ! -x "${LLAMA_SERVER_BIN}" ]; then
  echo "LLAMA_SERVER_BIN is not set to an executable in .env." >&2
  echo "Run ./scripts/download-prebuilt-llama-server.sh and put its output path" >&2
  echo "into .env as LLAMA_SERVER_BIN=..., then re-run this script." >&2
  exit 1
fi

LLAMA_SWAP_BIN="$(./scripts/download-llama-swap.sh 2>/dev/null | tail -n1)"
if [ -z "${LLAMA_SWAP_BIN}" ] || [ ! -x "${LLAMA_SWAP_BIN}" ]; then
  echo "Could not obtain a llama-swap binary." >&2
  exit 1
fi

echo "==> llama-swap : ${LLAMA_SWAP_BIN}"
echo "==> llama-server: ${LLAMA_SERVER_BIN}"
echo "==> Config      : data/models.yaml"
echo "==> Listening on: 127.0.0.1:${LLAMA_PORT}  (web UI at /ui, models at /v1/models)"

# LLAMA_SERVER_BIN, MODELS_DIR, MODEL_FILE, LLAMA_CTX_SIZE and LLAMA_THREADS
# are already exported above (set -a) for models.yaml's ${env.*} macros.
exec "${LLAMA_SWAP_BIN}" \
  -config data/models.yaml \
  -listen "127.0.0.1:${LLAMA_PORT}" \
  -watch-config
