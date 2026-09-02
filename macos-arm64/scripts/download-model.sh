#!/usr/bin/env bash
# Télécharge le modèle GGUF par défaut dans ./models s'il est absent.
# Voir ../../shared/model-notes.md pour changer de modèle.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
MODEL_FILE="${MODEL_FILE:-qwen2.5-coder-7b-instruct-q4_k_m.gguf}"
MODEL_REPO="${MODEL_REPO:-Qwen/Qwen2.5-Coder-7B-Instruct-GGUF}"

mkdir -p models

if [ -f "models/${MODEL_FILE}" ]; then
  echo "Modèle déjà présent : models/${MODEL_FILE}"
  exit 0
fi

echo "Téléchargement de ${MODEL_FILE} depuis ${MODEL_REPO}..."
curl -fL --progress-bar \
  "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
  -o "models/${MODEL_FILE}.part"
mv "models/${MODEL_FILE}.part" "models/${MODEL_FILE}"
echo "OK : models/${MODEL_FILE}"
