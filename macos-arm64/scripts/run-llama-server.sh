#!/usr/bin/env bash
# Runs llama-server natively (Metal), bound to 127.0.0.1 so that only the
# hermes container (via host.docker.internal) and this machine can reach it.
#
# Replaces the former llama-swap-based launcher (run-llama-swap.sh):
# this deployment only ever runs one model, never switches it at
# runtime, so llama-swap's routing/multi-model layer bought nothing here
# — see docs/ARCHITECTURE.md and the 2026-09-15 change that removed it.
# The model stays loaded permanently (no idle-unload), which also avoids
# the 20-40 minute cold-prefill penalty a fresh model load costs on this
# repo's typical context size — see shared/hardware-sizing.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-65536}"
MODELS_DIR="$(pwd)/models"

if [ -z "${LLAMA_SERVER_BIN:-}" ] || [ ! -x "${LLAMA_SERVER_BIN}" ]; then
  echo "LLAMA_SERVER_BIN is not set to an executable in .env." >&2
  echo "Run ./scripts/download-prebuilt-llama-server.sh and put its output path" >&2
  echo "into .env as LLAMA_SERVER_BIN=..., then re-run this script." >&2
  exit 1
fi

if [ -z "${MODEL_FILE:-}" ] || [ ! -f "${MODELS_DIR}/${MODEL_FILE}" ]; then
  echo "MODEL_FILE is not set in .env, or ${MODELS_DIR}/\${MODEL_FILE} doesn't exist." >&2
  echo "See ../shared/managing-models.md for how to download a model." >&2
  exit 1
fi

echo "==> llama-server: ${LLAMA_SERVER_BIN}"
echo "==> Model       : ${MODELS_DIR}/${MODEL_FILE}"
echo "==> Listening on: 127.0.0.1:${LLAMA_PORT}"

# Flags match what config/models.yaml.example used to pass through
# llama-swap — see that file's own history and shared/model-notes.md for
# why each one is here (KV-cache quantization issue #52, --predict cap
# issue #82, --repeat-penalty issue #101).
exec "${LLAMA_SERVER_BIN}" \
  --port "${LLAMA_PORT}" \
  --host 127.0.0.1 \
  --model "${MODELS_DIR}/${MODEL_FILE}" \
  --ctx-size "${LLAMA_CTX_SIZE}" \
  -ngl 99 \
  --jinja \
  --flash-attn on \
  -ctk q8_0 \
  -ctv q8_0 \
  --predict 4096 \
  --repeat-penalty 1.1
