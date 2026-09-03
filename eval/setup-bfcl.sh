#!/usr/bin/env bash
# Installs BFCL (Berkeley Function-Calling Leaderboard, bfcl-eval on PyPI)
# into an isolated venv — issue #29, part of #28.
# See ../shared/model-evaluation.md for why this doesn't need vLLM.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found on PATH — install Python 3 first." >&2
  exit 1
fi

# Deliberately OUTSIDE this repo's own tree — on macOS with iCloud Drive's
# "Optimize Mac Storage" enabled (which syncs ~/Documents and can evict any
# file to save local space, re-fetching on demand), a venv's thousands of
# small package files inside a repo under ~/Documents can get evicted and
# then fail to re-hydrate — confirmed live, 2026-09-03: `import transformers`
# started failing with `TimeoutError: [Errno 60] Operation timed out` on a
# previously-working venv, reproduced via a plain file read (`wc -l` on the
# same file, same error) — not a bfcl-eval or Python bug. Keeping the repo
# itself fully synced (the actual point of iCloud Drive here) while routing
# large, disposable, regenerate-anytime installs through the OS's own cache
# directory sidesteps this entirely, on macOS and Linux alike.
EVAL_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-eval"
VENV_DIR="${EVAL_CACHE_DIR}/venv"
mkdir -p "${EVAL_CACHE_DIR}"

if [ ! -d "${VENV_DIR}" ]; then
  echo "==> Creating venv at ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi

echo "==> Installing bfcl-eval"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet bfcl-eval
# bfcl-eval's Qwen support pulls in qwen_agent, which imports soundfile at
# module load time even though this deployment never uses Qwen's API path
# — without it, `bfcl` crashes on startup for every model, not just Qwen.
# Found live-testing this script, not documented upstream.
"${VENV_DIR}/bin/pip" install --quiet soundfile
# The local-inference handler (used by --skip-server-setup) imports
# transformers directly for tokenizer/config loading, but the base
# `pip install bfcl-eval` doesn't declare it as a dependency — only
# bfcl-eval's own "oss-eval-vllm" extra does, and that extra also pulls
# in the full vllm==0.8.5 package (GPU-oriented, ~multi-GB, and entirely
# unused here since --skip-server-setup means vllm never actually serves
# anything). Installing transformers directly avoids that unnecessary
# weight. Found live-testing this script, not documented upstream.
"${VENV_DIR}/bin/pip" install --quiet transformers

export BFCL_PROJECT_ROOT="${EVAL_CACHE_DIR}/bfcl-workspace"
mkdir -p "${BFCL_PROJECT_ROOT}"

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
TOKENIZER_DIR="${BFCL_PROJECT_ROOT}/tokenizers/meta-llama-3.1-8b-instruct"
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

if [ ! -f "${BFCL_PROJECT_ROOT}/.env" ]; then
  BFCL_PKG_DIR="$("${VENV_DIR}/bin/python3" -c 'import bfcl_eval, pathlib; print(pathlib.Path(bfcl_eval.__path__[0]))')"
  cp "${BFCL_PKG_DIR}/.env.example" "${BFCL_PROJECT_ROOT}/.env"
  echo "==> ${BFCL_PROJECT_ROOT}/.env created from bfcl-eval's own template"
else
  echo "==> ${BFCL_PROJECT_ROOT}/.env already exists — left untouched"
fi

echo ""
echo "Setup done. This deployment doesn't need any of the API keys in that"
echo ".env (no proprietary-model categories are used here — see"
echo "../shared/model-evaluation.md) — run-bfcl.sh sets VLLM_ENDPOINT/"
echo "VLLM_PORT itself, pointed at your running llama-swap."
echo ""
echo "Venv and workspace live at ${EVAL_CACHE_DIR} (outside this repo,"
echo "regenerate anytime by re-running this script)."
echo ""
echo "Next: ./run-bfcl.sh <llama-swap-host> <llama-swap-port>"
