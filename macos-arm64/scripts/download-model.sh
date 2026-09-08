#!/usr/bin/env bash
# Downloads the default GGUF model into ./models if it's missing.
# See ../../shared/model-notes.md to use a different model.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [ -f .env ] && source .env; set +a
MODEL_FILE="${MODEL_FILE:-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf}"
MODEL_REPO="${MODEL_REPO:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF}"

mkdir -p models

MODEL_PATH="models/${MODEL_FILE}"
if [ -f "${MODEL_PATH}" ]; then
  # -f alone doesn't catch macOS's "Optimize Mac Storage" (iCloud Drive)
  # evicting this file's content to 0 bytes while its listed size stays
  # correct -- the same failure mode already confirmed live against
  # llama-server (see ../README.md's troubleshooting table), equally
  # possible here since ./models lives under the same iCloud-synced tree.
  if [ -s "${MODEL_PATH}" ]; then
    echo "Model already present: ${MODEL_PATH}"
    exit 0
  fi
  echo "!! ${MODEL_PATH} exists but is EMPTY (0 bytes) -- likely iCloud"
  echo "!! Drive eviction, not a real deletion."
  if command -v brctl >/dev/null 2>&1; then
    echo "==> Attempting to re-materialize via 'brctl download'..."
    brctl download "${MODEL_PATH}" >/dev/null 2>&1 || true
    sleep 2
  fi
  if [ -s "${MODEL_PATH}" ]; then
    echo "==> Recovered: ${MODEL_PATH}"
    exit 0
  fi
  echo "==> Still empty -- re-downloading."
  rm -f "${MODEL_PATH}"
fi

echo "Downloading ${MODEL_FILE} from ${MODEL_REPO}..."
curl -fL --progress-bar \
  "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
  -o "models/${MODEL_FILE}.part"
mv "models/${MODEL_FILE}.part" "models/${MODEL_FILE}"
echo "OK: models/${MODEL_FILE}"
