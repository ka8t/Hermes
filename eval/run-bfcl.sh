#!/usr/bin/env bash
# Runs BFCL against a running llama-swap endpoint, entirely inside the
# hermes-eval-bfcl Docker image — issue #29, part of #28, see #51.
# Run ./setup-bfcl.sh once first. See ../shared/model-evaluation.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORKSPACE_DIR="$(pwd)/bfcl-workspace"
TOKENIZER_DIR="${WORKSPACE_DIR}/tokenizers/meta-llama-3.1-8b-instruct"
if [ ! -f "${TOKENIZER_DIR}/tokenizer_config.json" ] || [ ! -f "${WORKSPACE_DIR}/.env" ]; then
  echo "${WORKSPACE_DIR} not fully set up — run ./setup-bfcl.sh first." >&2
  exit 1
fi
if ! docker image inspect hermes-eval-bfcl >/dev/null 2>&1; then
  echo "hermes-eval-bfcl image not found — run ./setup-bfcl.sh first." >&2
  exit 1
fi

LLAMA_SWAP_HOST="${1:-127.0.0.1}"
LLAMA_SWAP_PORT="${2:-8080}"
# BFCL's flag names its own vLLM-based origin, but --skip-server-setup
# (baked into entrypoint.sh) means it's never actually used for anything
# but pointing at *some* OpenAI-compatible endpoint — llama-swap qualifies
# (see ../shared/model-evaluation.md for the sourced confirmation).
MODEL="${BFCL_MODEL:-meta-llama/Llama-3.1-8B-Instruct-FC}"
CATEGORIES="${BFCL_CATEGORIES:-simple_python,parallel,multi_turn}"

echo "==> Checking ${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT} is reachable"
if ! curl -sf "http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/health" >/dev/null; then
  echo "!! http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/health not reachable." >&2
  echo "!! Point this script at a running llama-swap: ./run-bfcl.sh <host> <port>" >&2
  exit 1
fi

# The real model ID llama-swap actually routes on (e.g. "llama-3.1-8b-instruct"),
# read from its own /v1/models — not guessed, and not the same string BFCL
# will put in its own requests (see model_alias_proxy.py).
REAL_MODEL_ID="$(curl -sf "http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
if [ -z "${REAL_MODEL_ID}" ]; then
  echo "!! Could not read a model ID from http://${LLAMA_SWAP_HOST}:${LLAMA_SWAP_PORT}/v1/models." >&2
  exit 1
fi

# The container needs to reach llama-swap on the host. When pointed at
# loopback (the common case: llama-swap running directly on this
# machine), rewrite to host.docker.internal, which --add-host below
# makes resolvable inside the container on both Docker Desktop (macOS,
# where it already works without the flag) and Linux (Docker 20.10+,
# where the flag is required) — confirmed against Docker's own docs.
# Any other host (a real hostname/IP, e.g. a separate machine) is passed
# through unchanged, since it's already reachable from inside a container.
case "${LLAMA_SWAP_HOST}" in
  127.0.0.1|localhost) UPSTREAM_HOST="host.docker.internal" ;;
  *) UPSTREAM_HOST="${LLAMA_SWAP_HOST}" ;;
esac

echo "==> Running BFCL in Docker: model=${MODEL} categories=${CATEGORIES} (via proxy -> ${REAL_MODEL_ID})"
# hermes-eval-bfcl defaults to a fixed non-root UID (see Dockerfile, issue
# #57); --user overrides that to the invoking host user so writes into the
# host-owned bfcl-workspace/ bind mount below don't hit an EACCES from a
# UID mismatch.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --add-host=host.docker.internal:host-gateway \
  -v "${WORKSPACE_DIR}:/workspace" \
  -e UPSTREAM_HOST="${UPSTREAM_HOST}" \
  -e UPSTREAM_PORT="${LLAMA_SWAP_PORT}" \
  -e REAL_MODEL_ID="${REAL_MODEL_ID}" \
  -e MODEL="${MODEL}" \
  -e CATEGORIES="${CATEGORIES}" \
  hermes-eval-bfcl

echo ""
echo "Results: ${WORKSPACE_DIR}/result/"
echo "Scores:  ${WORKSPACE_DIR}/score/"
