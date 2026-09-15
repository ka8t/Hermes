#!/usr/bin/env bash
# Integration smoke test for the linux-x86_64-vps configuration's model
# serving path: brings up the real llama-server service from
# linux-x86_64-vps/docker-compose.yml (not a mock), with a tiny model
# swapped in for speed, and checks it actually serves a completion.
# Does NOT touch the hermes service (no Telegram token needed here — that
# seam is Hermes's own gateway, not this repo's model-serving wiring).
#
# Requires: Docker. Downloads ~350MB (test model) + the official
# llama-server binary once (cached under linux-x86_64-vps/models and
# linux-x86_64-vps/vendor).
#
#   ./test/smoke-vps.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../linux-x86_64-vps"

TEST_MODEL_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
TEST_MODEL_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"

cleanup() {
  echo "==> Tearing down"
  docker compose down -v >/dev/null 2>&1 || true
  rm -f .env
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

if [ ! -f "models/${TEST_MODEL_FILE}" ]; then
  echo "==> Downloading test model (~350MB, cached for next run)"
  curl -fL --progress-bar \
    "https://huggingface.co/${TEST_MODEL_REPO}/resolve/main/${TEST_MODEL_FILE}" \
    -o "models/${TEST_MODEL_FILE}"
fi

echo "==> Fetching the official llama-server binary (cached for next run)"
./scripts/download-prebuilt-llama-server.sh >/dev/null

echo "==> Starting llama-server (the real docker-compose.yml service, not hermes)"
docker compose up -d --build llama-server

echo "==> Waiting for it to report healthy"
for _ in $(seq 1 20); do
  status="$(docker inspect --format='{{.State.Health.Status}}' llama-server 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "FAIL: llama-server never became healthy"
  docker compose logs llama-server
  exit 1
fi
echo "ok   llama-server is healthy"

echo "==> GET /v1/models should list a real model"
models_json="$(curl -sf http://127.0.0.1:8080/v1/models)"
# Read the real model ID rather than assuming one — llama-server reports
# the loaded .gguf's own path/name here, not a fixed label, so it never
# matches a hardcoded ID once a different test model is swapped in.
# Asserting a hard-coded ID here was a real bug (issue #54): this check
# passed only by accident, or never at all — confirmed CI had been
# failing on this exact line for 10+ consecutive runs before the fix.
REAL_MODEL_ID="$(echo "$models_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"
if [ -z "${REAL_MODEL_ID}" ]; then
  echo "FAIL: no model ID found in $models_json"
  exit 1
fi
echo "ok   model ID present: ${REAL_MODEL_ID}"

echo "==> POST /v1/chat/completions should get a real reply"
reply="$(curl -sf http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${REAL_MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: OK\"}],\"max_tokens\":10}")"
echo "$reply" | grep -q '"content"' \
  && echo "ok   got a completion: $reply" \
  || { echo "FAIL: no completion in $reply"; exit 1; }

echo
echo "smoke-vps: all checks passed"
