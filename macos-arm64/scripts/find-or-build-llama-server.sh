#!/usr/bin/env bash
# Locates a llama-server binary with Metal support, preferring (in order):
#   1. an explicit override
#   2. a llama.cpp build already present elsewhere on this machine
#   3. a Homebrew install
#   4. the official prebuilt binary (downloaded, no compiler needed)
#   5. building from source, as a last resort
# Prints only its path on stdout, so it can be used as:
# LLAMA_SERVER_BIN="$(./find-or-build-llama-server.sh)"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# 1. Explicit override
if [ -n "${LLAMA_SERVER_BIN:-}" ] && [ -x "${LLAMA_SERVER_BIN}" ]; then
  echo "${LLAMA_SERVER_BIN}"
  exit 0
fi

# 2. A llama.cpp clone/build already present elsewhere on this machine
#    (convention used by this project: ~/Documents/Code/llama.cpp)
CANDIDATE="${HOME}/Documents/Code/llama.cpp/build/bin/llama-server"
if [ -x "${CANDIDATE}" ]; then
  echo "${CANDIDATE}"
  exit 0
fi

# 3. Installed via Homebrew (`brew install llama.cpp`)
if command -v llama-server >/dev/null 2>&1; then
  command -v llama-server
  exit 0
fi

# 4. Official prebuilt binary (fast, no compiler required) — see
#    ../../shared/prebuilt-binaries.md for what's actually in it.
#    Skip this tier with LLAMA_BUILD_FROM_SOURCE=1 if you need custom build flags.
if [ "${LLAMA_BUILD_FROM_SOURCE:-0}" != "1" ]; then
  if PREBUILT_BIN="$(./scripts/download-prebuilt-llama-server.sh 2>/dev/null)" \
     && [ -n "${PREBUILT_BIN}" ] && [ -x "${PREBUILT_BIN}" ]; then
    echo "${PREBUILT_BIN}"
    exit 0
  fi
  echo "==> Prebuilt binary unavailable, falling back to building from source" >&2
fi

# 5. Last resort: clone + build our own copy, with Metal, under ./vendor
VENDOR_DIR="$(pwd)/vendor/llama.cpp"
BUILT_BIN="${VENDOR_DIR}/build/bin/llama-server"

if [ ! -x "${BUILT_BIN}" ]; then
  {
    echo "==> Cloning + building locally into ${VENDOR_DIR}" >&2
    mkdir -p "$(dirname "${VENDOR_DIR}")"
    if [ ! -d "${VENDOR_DIR}" ]; then
      git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "${VENDOR_DIR}"
    fi
    cmake -S "${VENDOR_DIR}" -B "${VENDOR_DIR}/build" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "${VENDOR_DIR}/build" --target llama-server -j"$(sysctl -n hw.ncpu)"
  } >&2
fi

echo "${BUILT_BIN}"
