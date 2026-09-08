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

# A binary can have -x set even when macOS's "Optimize Mac Storage" (iCloud
# Drive) has evicted its actual content to 0 bytes -- confirmed live this
# session, on this exact file (see README.md's troubleshooting table). -x
# alone (permission bits) never catches this; -s (non-empty) does. Try
# brctl to re-materialize before giving up on an otherwise-good candidate.
usable_binary() {
  local path="$1"
  [ -x "${path}" ] || return 1
  if [ -s "${path}" ]; then
    return 0
  fi
  echo "!! ${path} exists and is executable but EMPTY (0 bytes) -- likely" >&2
  echo "!! iCloud Drive eviction (see this README's troubleshooting table)." >&2
  if command -v brctl >/dev/null 2>&1; then
    echo "==> Attempting to re-materialize via 'brctl download'..." >&2
    brctl download "${path}" >/dev/null 2>&1 || true
    sleep 2
  fi
  [ -s "${path}" ]
}

# 1. Explicit override — an explicit path is deliberate user intent, so a
# broken one fails loudly instead of silently substituting a different
# binary underneath the caller.
if [ -n "${LLAMA_SERVER_BIN:-}" ]; then
  if usable_binary "${LLAMA_SERVER_BIN}"; then
    echo "${LLAMA_SERVER_BIN}"
    exit 0
  fi
  echo "!! LLAMA_SERVER_BIN=${LLAMA_SERVER_BIN} is set but not a usable binary" \
       "(missing, not executable, or empty and unrecoverable)." >&2
  exit 1
fi

# 2. A llama.cpp clone/build already present elsewhere on this machine
#    (convention used by this project: ~/Documents/Code/llama.cpp)
CANDIDATE="${HOME}/Documents/Code/llama.cpp/build/bin/llama-server"
if usable_binary "${CANDIDATE}"; then
  echo "${CANDIDATE}"
  exit 0
fi

# 3. Installed via Homebrew (`brew install llama.cpp`)
if command -v llama-server >/dev/null 2>&1 && usable_binary "$(command -v llama-server)"; then
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
