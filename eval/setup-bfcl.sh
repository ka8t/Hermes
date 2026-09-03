#!/usr/bin/env bash
# Builds the hermes-eval-bfcl Docker image and prepares eval/bfcl-workspace
# — issue #29, part of #28. See ../shared/model-evaluation.md and #51.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH — install Docker first." >&2
  exit 1
fi

echo "==> Building hermes-eval-bfcl image (bfcl-eval, soundfile, transformers)"
docker build -t hermes-eval-bfcl -f Dockerfile .

WORKSPACE_DIR="$(pwd)/bfcl-workspace"
mkdir -p "${WORKSPACE_DIR}"

# BFCL's local-inference handler loads the model's tokenizer via
# transformers' AutoTokenizer, from the model's *original* HuggingFace
# repo (meta-llama/Llama-3.1-8B-Instruct) — separate from and in addition
# to llama-swap/llama.cpp actually running inference. That repo is
# license-gated (requires a HuggingFace account + accepting Meta's terms).
# This deployment doesn't use gated/account-walled sources anywhere else
# (see shared/model-notes.md — the GGUF itself comes from bartowski's
# ungated re-upload) — so this downloads just the small tokenizer files
# (not model weights) from NousResearch's own public, ungated mirror of
# the same model (NousResearch also publishes Hermes Agent itself) —
# confirmed ungated live (`"gated": false`, plain download, no token).
# These are a handful of small JSON files — kept on the host, inside the
# repo, unlike the venv (see Dockerfile's comment and #51).
TOKENIZER_DIR="${WORKSPACE_DIR}/tokenizers/meta-llama-3.1-8b-instruct"
if [ ! -f "${TOKENIZER_DIR}/tokenizer_config.json" ]; then
  echo "==> Downloading tokenizer files (not model weights) from an ungated mirror"
  mkdir -p "${TOKENIZER_DIR}"
  for f in config.json tokenizer_config.json tokenizer.json special_tokens_map.json; do
    curl -fL --silent \
      "https://huggingface.co/NousResearch/Meta-Llama-3.1-8B-Instruct/resolve/main/${f}" \
      -o "${TOKENIZER_DIR}/${f}"
  done
else
  echo "==> Tokenizer files already present at ${TOKENIZER_DIR}"
fi

if [ ! -f "${WORKSPACE_DIR}/.env" ]; then
  echo "==> Creating ${WORKSPACE_DIR}/.env from bfcl-eval's own template"
  docker run --rm --entrypoint python3 hermes-eval-bfcl -c \
    'import bfcl_eval, pathlib, sys; sys.stdout.write((pathlib.Path(bfcl_eval.__path__[0]) / ".env.example").read_text())' \
    > "${WORKSPACE_DIR}/.env"
else
  echo "==> ${WORKSPACE_DIR}/.env already exists — left untouched"
fi

echo ""
echo "Setup done. This deployment doesn't need any of the API keys in that"
echo ".env (no proprietary-model categories are used here — see"
echo "../shared/model-evaluation.md) — run-bfcl.sh sets VLLM_ENDPOINT/"
echo "VLLM_PORT itself, pointed at your running llama-swap."
echo ""
echo "Everything lives inside eval/ (the image build, bfcl-workspace/ for"
echo "results and small config files) — no host installs, no directories"
echo "outside this repo (see #51)."
echo ""
echo "Next: ./run-bfcl.sh <llama-swap-host> <llama-swap-port>"
