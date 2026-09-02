#!/usr/bin/env bash
# Localise un binaire llama-server compilé avec le support Metal, ou le
# construit si besoin. Écrit son chemin sur stdout (et uniquement ça),
# pour pouvoir faire : LLAMA_SERVER_BIN="$(./find-or-build-llama-server.sh)"
set -euo pipefail

# 1. Override explicite
if [ -n "${LLAMA_SERVER_BIN:-}" ] && [ -x "${LLAMA_SERVER_BIN}" ]; then
  echo "${LLAMA_SERVER_BIN}"
  exit 0
fi

# 2. Un clone/build llama.cpp déjà présent ailleurs sur cette machine
#    (convention utilisée par ce projet : ~/Documents/Code/llama.cpp)
CANDIDATE="${HOME}/Documents/Code/llama.cpp/build/bin/llama-server"
if [ -x "${CANDIDATE}" ]; then
  echo "${CANDIDATE}"
  exit 0
fi

# 3. Installé via Homebrew (`brew install llama.cpp`)
if command -v llama-server >/dev/null 2>&1; then
  command -v llama-server
  exit 0
fi

# 4. Sinon, on construit notre propre copie, avec Metal, dans ./vendor
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/llama.cpp"
BUILT_BIN="${VENDOR_DIR}/build/bin/llama-server"

if [ ! -x "${BUILT_BIN}" ]; then
  {
    echo "==> Aucun llama-server trouvé — clonage + build local dans ${VENDOR_DIR}" >&2
    mkdir -p "$(dirname "${VENDOR_DIR}")"
    if [ ! -d "${VENDOR_DIR}" ]; then
      git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "${VENDOR_DIR}"
    fi
    cmake -S "${VENDOR_DIR}" -B "${VENDOR_DIR}/build" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "${VENDOR_DIR}/build" --target llama-server -j"$(sysctl -n hw.ncpu)"
  } >&2
fi

echo "${BUILT_BIN}"
