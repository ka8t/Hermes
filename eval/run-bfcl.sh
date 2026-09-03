#!/usr/bin/env bash
# Runs BFCL against a running llama-swap endpoint — issue #29, part of #28.
# Run ./setup-bfcl.sh once first. See ../shared/model-evaluation.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Same out-of-repo cache location as setup-bfcl.sh — see that script's
# comment for why (iCloud Drive "Optimize Mac Storage" eviction, confirmed
# live 2026-09-03).
EVAL_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-eval"
VENV_DIR="${EVAL_CACHE_DIR}/venv"
BFCL_BIN="${VENV_DIR}/bin/bfcl"

if [ ! -x "${BFCL_BIN}" ]; then
  echo "${VENV_DIR} not found — run ./setup-bfcl.sh first." >&2
  exit 1
fi

LLAMA_SWAP_HOST="${1:-127.0.0.1}"
LLAMA_SWAP_PORT="${2:-8080}"
# BFCL's flag names its own vLLM-based origin, but --skip-server-setup
# below means it's never actually used for anything but pointing at
# *some* OpenAI-compatible endpoint — llama-swap qualifies (see
# ../shared/model-evaluation.md for the sourced confirmation, and the
# note about VLLM_ENDPOINT/VLLM_PORT being the real env var names,
# correcting an earlier draft of that doc that had the wrong names).

MODEL="${BFCL_MODEL:-meta-llama/Llama-3.1-8B-Instruct-FC}"
CATEGORIES="${BFCL_CATEGORIES:-simple,parallel,multi_turn}"

export BFCL_PROJECT_ROOT="${EVAL_CACHE_DIR}/bfcl-workspace"
TOKENIZER_DIR="${BFCL_PROJECT_ROOT}/tokenizers/meta-llama-3.1-8b-instruct"
if [ ! -f "${TOKENIZER_DIR}/tokenizer_config.json" ]; then
  echo "Tokenizer files not found at ${TOKENIZER_DIR} — run ./setup-bfcl.sh first." >&2
  exit 1
fi

echo "==> Checking ${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT} is reachable"
if ! curl -sf "http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/health" >/dev/null; then
  echo "!! http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/health not reachable." >&2
  echo "!! Point this script at a running llama-swap: ./run-bfcl.sh <host> <port>" >&2
  exit 1
fi

# The real model ID llama-swap actually routes on (e.g. "llama-3.1-8b-instruct"),
# read from its own /v1/models — not guessed, and not the same string BFCL
# will put in its own requests (see the proxy note below).
REAL_MODEL_ID="$(curl -sf "http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
if [ -z "${REAL_MODEL_ID}" ]; then
  echo "!! Could not read a model ID from http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/v1/models." >&2
  exit 1
fi

# BFCL's local-inference handler hard-codes the "model" field it sends to
# either --local-model-path's filesystem path or its own internal handler
# name (e.g. "meta-llama/Llama-3.1-8B-Instruct-FC") — never llama-swap's
# real model ID, and there's no BFCL flag to override this (checked its
# source directly — model_handler/local_inference/base_oss_handler.py's
# `model=self.model_path_or_id`). Found live-testing this script: without
# the proxy below, llama-swap rejects every request with "no router for
# requested model". model_alias_proxy.py sits in between and rewrites the
# model field to REAL_MODEL_ID before forwarding.
PROXY_PORT="${BFCL_PROXY_PORT:-8091}"
"${VENV_DIR}/bin/python3" model_alias_proxy.py \
  --listen-port "${PROXY_PORT}" \
  --upstream-host "${LLAMA_SWAP_HOST}" \
  --upstream-port "${LLAMA_SWAP_PORT}" \
  --real-model-id "${REAL_MODEL_ID}" &
PROXY_PID=$!
trap 'kill "${PROXY_PID}" 2>/dev/null || true' EXIT

# Wait for the proxy to actually be listening before pointing BFCL at it.
for _ in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:${PROXY_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# BFCL loads ${BFCL_PROJECT_ROOT}/.env with python-dotenv's override=True,
# which silently overwrites any VLLM_ENDPOINT/VLLM_PORT exported in this
# shell with whatever bfcl-eval's own .env.example template hard-codes
# (VLLM_ENDPOINT=localhost, VLLM_PORT=1053) — exporting the env vars here
# has no effect. Found live-testing this script: BFCL hung silently,
# retrying a connection to the wrong port forever, with no error message.
# Editing the .env file directly is the only thing that actually works.
# Portable across BSD sed (macOS) and GNU sed (Linux VPS) — `sed -i` needs
# a backup-suffix argument on one and not the other; a temp file avoids
# the difference entirely.
sed \
  -e "s/^VLLM_ENDPOINT=.*/VLLM_ENDPOINT=127.0.0.1/" \
  -e "s/^VLLM_PORT=.*/VLLM_PORT=${PROXY_PORT}/" \
  "${BFCL_PROJECT_ROOT}/.env" > "${BFCL_PROJECT_ROOT}/.env.tmp"
mv "${BFCL_PROJECT_ROOT}/.env.tmp" "${BFCL_PROJECT_ROOT}/.env"

echo "==> Generating responses: model=${MODEL} categories=${CATEGORIES} (via proxy -> ${REAL_MODEL_ID})"
"${BFCL_BIN}" generate \
  --model "${MODEL}" \
  --test-category "${CATEGORIES}" \
  --skip-server-setup \
  --local-model-path "${TOKENIZER_DIR}" \
  --allow-overwrite

echo "==> Scoring responses"
"${BFCL_BIN}" evaluate \
  --model "${MODEL}" \
  --test-category "${CATEGORIES}"

echo ""
echo "Results: ${BFCL_PROJECT_ROOT}/result/"
echo "Scores:  ${BFCL_PROJECT_ROOT}/score/"
