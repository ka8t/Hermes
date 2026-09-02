#!/usr/bin/env bash
# Integration smoke test for the macos-arm64 configuration's model serving
# path: runs the real scripts/download-prebuilt-llama-server.sh,
# scripts/download-llama-swap.sh and scripts/run-llama-swap.sh (not mocks),
# with a tiny model swapped in for speed, and checks it actually serves a
# completion via Metal.
#
# Local only — needs an actual Apple Silicon Mac (Metal), so this does not
# run in CI (see test/smoke-vps.sh for the CI-friendly Linux/CPU equivalent
# of the same wiring). Does NOT touch Docker/hermes — that seam is Hermes's
# own gateway, not this repo's model-serving wiring.
#
#   ./test/smoke-macos.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../macos-arm64"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "SKIP: this test requires an Apple Silicon Mac" >&2
  exit 0
fi

TEST_MODEL_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
TEST_MODEL_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"

SWAP_PID=""
cleanup() {
  echo "==> Tearing down"
  [ -n "${SWAP_PID}" ] && kill "${SWAP_PID}" 2>/dev/null || true
  rm -f .env
  rm -rf data
}
trap cleanup EXIT

echo "==> Preparing a throwaway .env pointing at a tiny test model"
cp .env.example .env
sed -i '' "s/^MODEL_FILE=.*/MODEL_FILE=${TEST_MODEL_FILE}/" .env
sed -i '' "s#^MODEL_REPO=.*#MODEL_REPO=${TEST_MODEL_REPO}#" .env

echo "==> Ensuring a llama-server binary is available"
LLAMA_SERVER_BIN="$(./scripts/download-prebuilt-llama-server.sh 2>/dev/null | tail -n1)"
sed -i '' "s#^LLAMA_SERVER_BIN=.*#LLAMA_SERVER_BIN=${LLAMA_SERVER_BIN}#" .env

./scripts/download-model.sh

mkdir -p data
cp config/config.yaml.example data/config.yaml
cp config/models.yaml.example data/models.yaml

echo "==> Starting llama-swap in the background"
./scripts/run-llama-swap.sh >/tmp/hermes-smoke-macos.log 2>&1 &
SWAP_PID=$!

echo "==> Waiting for /health"
ok=0
for _ in $(seq 1 20); do
  if curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" -ne 1 ]; then
  echo "FAIL: llama-swap never answered /health"
  cat /tmp/hermes-smoke-macos.log
  exit 1
fi
echo "ok   llama-swap is up"

echo "==> GET /v1/models should list the configured model"
models_json="$(curl -sf http://127.0.0.1:8080/v1/models)"
echo "$models_json" | grep -q '"qwen2.5-coder-7b"' \
  && echo "ok   model ID present" \
  || { echo "FAIL: model ID missing from $models_json"; exit 1; }

echo "==> POST /v1/chat/completions should get a real reply (spawns llama-server, Metal)"
reply="$(curl -sf http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-7b","messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":10}')"
echo "$reply" | grep -q '"content"' \
  && echo "ok   got a completion: $reply" \
  || { echo "FAIL: no completion in $reply"; exit 1; }

echo
echo "smoke-macos: all checks passed"
