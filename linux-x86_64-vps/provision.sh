#!/usr/bin/env bash
# Provisionnement d'un VPS Ubuntu 22.04+/x86-64 neuf pour cette stack
# (llama.cpp + Hermes Agent, tous deux en Docker).
#
# À lancer une fois, en root, sur le VPS :
#   curl -fsSL https://raw.githubusercontent.com/ka8t/Hermes/main/linux-x86_64-vps/provision.sh | bash
# ou, une fois le dépôt cloné sur le VPS :
#   cd linux-x86_64-vps && ./provision.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "==> Installation de Docker Engine + plugin Compose (si absents)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y docker-compose-plugin
fi

echo "==> Préparation des répertoires persistants"
mkdir -p data models

if [ ! -f .env ]; then
  cp .env.example .env
  echo "!! Fichier .env créé depuis .env.example — éditez-le (token Telegram, etc.) avant de continuer."
fi

if [ ! -f data/config.yaml ]; then
  cp config/config.yaml.example data/config.yaml
  echo "==> data/config.yaml initialisé depuis config/config.yaml.example"
fi

MODEL_FILE="$(grep -E '^MODEL_FILE=' .env | cut -d= -f2)"
MODEL_FILE="${MODEL_FILE:-qwen2.5-coder-7b-instruct-q4_k_m.gguf}"

if [ ! -f "models/${MODEL_FILE}" ]; then
  echo "==> Téléchargement du modèle ${MODEL_FILE} (voir ../shared/model-notes.md pour changer de modèle)"
  curl -fL --progress-bar \
    "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/${MODEL_FILE}" \
    -o "models/${MODEL_FILE}"
else
  echo "==> Modèle déjà présent : models/${MODEL_FILE}"
fi

echo ""
echo "Provisionnement terminé. Étapes restantes :"
echo "  1. Éditer .env (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS — voir ../shared/telegram-setup.md)"
echo "  2. docker compose up -d"
echo "  3. docker compose logs -f llama-server   # attendre 'server is listening'"
echo "  4. docker compose exec hermes hermes gateway setup   # une seule fois, pour Telegram"
