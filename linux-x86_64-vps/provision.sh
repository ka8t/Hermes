#!/usr/bin/env bash
# Provisions a fresh Ubuntu 22.04+/x86-64 VPS for this stack
# (llama.cpp + Hermes Agent, both in Docker).
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
fi

if [ ! -f data/config.yaml ]; then
  cp config/config.yaml.example data/config.yaml
  echo "==> data/config.yaml initialized from config/config.yaml.example"
fi

MODEL_FILE="$(grep -E '^MODEL_FILE=' .env | cut -d= -f2)"
MODEL_FILE="${MODEL_FILE:-qwen2.5-coder-7b-instruct-q4_k_m.gguf}"

if [ ! -f "models/${MODEL_FILE}" ]; then
  echo "==> Downloading model ${MODEL_FILE} (see ../shared/model-notes.md to change models)"
  curl -fL --progress-bar \
    "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/${MODEL_FILE}" \
    -o "models/${MODEL_FILE}"
else
  echo "==> Model already present: models/${MODEL_FILE}"
fi

echo ""
echo "Provisioning done. Remaining steps:"
echo "  1. Edit .env (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS — see ../shared/telegram-setup.md)"
echo "  2. docker compose up -d"
echo "  3. docker compose logs -f llama-server   # wait for 'server is listening'"
echo "  4. docker compose exec hermes hermes gateway setup   # once, for Telegram"
