#!/usr/bin/env bash
# Integration smoke test for the linux-x86_64-vps configuration's model
# serving path: brings up the real llama-swap service from
# linux-x86_64-vps/docker-compose.yml (not a mock), with a tiny model
# swapped in for speed, and checks it actually serves a completion.
# Does NOT touch the hermes service (no Telegram token needed here — that
# seam is Hermes's own gateway, not this repo's model-serving wiring).
#
# Requires: Docker. Downloads ~350MB once (cached under linux-x86_64-vps/models).
#
#   ./test/smoke-vps.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../linux-x86_64-vps"

TEST_MODEL_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
TEST_MODEL_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"

cleanup() {
  echo "==> Tearing down"
  docker compose down -v >/dev/null 2>&1 || true
  rm -f .env data/models.yaml
}
trap cleanup EXIT

echo "==> Preparing a throwaway .env pointing at a tiny test model"
cp .env.example .env
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/^MODEL_FILE=.*/MODEL_FILE=${TEST_MODEL_FILE}/" .env
else
  sed -i "s/^MODEL_FILE=.*/MODEL_FILE=${TEST_MODEL_FILE}/" .env
fi

mkdir -p models data
cp config/models.yaml.example data/models.yaml

if [ ! -f "models/${TEST_MODEL_FILE}" ]; then
  echo "==> Downloading test model (~350MB, cached for next run)"
  curl -fL --progress-bar \
    "https://huggingface.co/${TEST_MODEL_REPO}/resolve/main/${TEST_MODEL_FILE}" \
    -o "models/${TEST_MODEL_FILE}"
fi

echo "==> Starting llama-swap (the real docker-compose.yml service, not hermes)"
docker compose up -d llama-swap

echo "==> Waiting for it to report healthy"
for _ in $(seq 1 20); do
  status="$(docker inspect --format='{{.State.Health.Status}}' llama-swap 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "FAIL: llama-swap never became healthy"
  docker compose logs llama-swap
  exit 1
fi
echo "ok   llama-swap is healthy"

echo "==> GET /v1/models should list the configured model"
models_json="$(curl -sf http://127.0.0.1:8080/v1/models)"
echo "$models_json" | grep -q '"qwen2.5-coder-7b"' \
  && echo "ok   model ID present" \
  || { echo "FAIL: model ID missing from $models_json"; exit 1; }

echo "==> POST /v1/chat/completions should get a real reply (spawns llama-server)"
reply="$(curl -sf http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-7b","messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":10}')"
echo "$reply" | grep -q '"content"' \
  && echo "ok   got a completion: $reply" \
  || { echo "FAIL: no completion in $reply"; exit 1; }

echo
echo "smoke-vps: all checks passed"
