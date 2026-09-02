#!/usr/bin/env bash
# Downloads the latest official prebuilt llama.cpp binary for macOS
# Apple Silicon (Metal included) into ./vendor/llama.cpp-prebuilt.
# See ../../shared/prebuilt-binaries.md for what's actually inside it.
# Prints the path to the extracted llama-server binary on stdout.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VENDOR_DIR="$(pwd)/vendor/llama.cpp-prebuilt"
mkdir -p "${VENDOR_DIR}"

ASSET_PATTERN="bin-macos-arm64.tar.gz"

echo "==> Looking up the latest ${ASSET_PATTERN} release on GitHub..." >&2
URL="$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases" \
  | grep -oE '"browser_download_url": *"[^"]*'"${ASSET_PATTERN}"'"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)"/\1/')"

if [ -z "${URL}" ]; then
  echo "Could not find a ${ASSET_PATTERN} asset in the latest releases." >&2
  exit 1
fi

ARCHIVE="${VENDOR_DIR}/$(basename "${URL}")"
if [ ! -f "${ARCHIVE}" ]; then
  echo "==> Downloading ${URL}" >&2
  curl -fL --progress-bar "${URL}" -o "${ARCHIVE}" >&2
fi

EXTRACT_DIR="${VENDOR_DIR}/current"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${ARCHIVE}" -C "${EXTRACT_DIR}" --strip-components=1

BIN="${EXTRACT_DIR}/llama-server"
chmod +x "${BIN}"
echo "==> Ready: ${BIN}" >&2
echo "${BIN}"
