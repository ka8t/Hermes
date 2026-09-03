#!/usr/bin/env bash
# Provisions a fresh Ubuntu 22.04+/x86-64 VPS for this stack
# (llama-swap + llama.cpp + Hermes Agent, all three in Docker).
#
# Run this once, as root, on the VPS:
#   curl -fsSL https://raw.githubusercontent.com/ka8t/Hermes/main/linux-x86_64-vps/provision.sh | bash
# or, once the repository is cloned on the VPS:
#   cd linux-x86_64-vps && ./provision.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "==> Installing Docker Engine + Compose plugin (if missing)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y docker-compose-plugin
fi

echo "==> Preparing persistent directories"
mkdir -p data models

if [ ! -f .env ]; then
  cp .env.example .env
  echo "!! .env created from .env.example — edit it (Telegram token, etc.) before continuing."

  # .env.example's LLAMA_THREADS=2 is a conservative default sized for the
  # smallest documented reference VPS (2 vCPU) — auto-detect this box's
  # real core count instead of silently leaving it under-provisioned, since
  # llama.cpp's prefill/generation throughput scales close to linearly with
  # thread count. Leaves one core for the OS/Docker/Hermes overhead.
  DETECTED_CORES="$(nproc)"
  if [ "${DETECTED_CORES}" -gt 2 ]; then
    LLAMA_THREADS="$((DETECTED_CORES - 1))"
    sed -i "s/^LLAMA_THREADS=.*/LLAMA_THREADS=${LLAMA_THREADS}/" .env
    echo "==> Detected ${DETECTED_CORES} vCPUs — set LLAMA_THREADS=${LLAMA_THREADS} in .env"
  fi
fi

if [ ! -f data/config.yaml ]; then
  cp config/config.yaml.example data/config.yaml
  echo "==> data/config.yaml initialized from config/config.yaml.example"
fi

if [ ! -f data/models.yaml ]; then
  cp config/models.yaml.example data/models.yaml
  echo "==> data/models.yaml initialized from config/models.yaml.example"
fi

MODEL_FILE="$(grep -E '^MODEL_FILE=' .env | cut -d= -f2)"
MODEL_FILE="${MODEL_FILE:-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf}"
MODEL_REPO="$(grep -E '^MODEL_REPO=' .env | cut -d= -f2)"
MODEL_REPO="${MODEL_REPO:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF}"

if [ ! -f "models/${MODEL_FILE}" ]; then
  echo "==> Downloading model ${MODEL_FILE} (see ../shared/model-notes.md to change models)"
  curl -fL --progress-bar \
    "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
    -o "models/${MODEL_FILE}"
else
  echo "==> Model already present: models/${MODEL_FILE}"
fi

echo ""
echo "Provisioning done. Remaining steps:"
echo "  1. Edit .env (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, and"
echo "     HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD — see ../shared/telegram-setup.md)"
echo "  2. docker compose up -d"
echo "  3. docker compose logs -f llama-swap   # wait for it to report healthy"
echo "  4. docker compose exec hermes hermes gateway setup   # once, for Telegram"
