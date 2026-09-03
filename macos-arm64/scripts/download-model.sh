#!/usr/bin/env bash
# Downloads the default GGUF model into ./models if it's missing.
# See ../../shared/model-notes.md to use a different model.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
MODEL_FILE="${MODEL_FILE:-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf}"
MODEL_REPO="${MODEL_REPO:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF}"

mkdir -p models

if [ -f "models/${MODEL_FILE}" ]; then
  echo "Model already present: models/${MODEL_FILE}"
  exit 0
fi

echo "Downloading ${MODEL_FILE} from ${MODEL_REPO}..."
curl -fL --progress-bar \
  "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
  -o "models/${MODEL_FILE}.part"
mv "models/${MODEL_FILE}.part" "models/${MODEL_FILE}"
echo "OK: models/${MODEL_FILE}"
