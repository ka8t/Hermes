#!/usr/bin/env bash
# Downloads the latest llama-swap release (stable semver, not a rolling
# build tag like llama.cpp) for Linux x86-64 into ./vendor/llama-swap.
# Only needed for the native (no-Docker) alternative — the Docker path
# uses ghcr.io/mostlygeek/llama-swap:cpu instead, which bundles both
# binaries. See ../../shared/prebuilt-binaries.md.
# Prints the path to the extracted llama-swap binary on stdout.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VENDOR_DIR="$(pwd)/vendor/llama-swap"
mkdir -p "${VENDOR_DIR}"

echo "==> Looking up the latest llama-swap release on GitHub..." >&2
URL="$(curl -fsSL "https://api.github.com/repos/mostlygeek/llama-swap/releases/latest" \
  | grep -oE '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)"/\1/')"

if [ -z "${URL}" ]; then
  echo "Could not find a linux_amd64 asset in the latest llama-swap release." >&2
  exit 1
fi

ARCHIVE="${VENDOR_DIR}/$(basename "${URL}")"
if [ ! -f "${ARCHIVE}" ]; then
  echo "==> Downloading ${URL}" >&2
  curl -fL --progress-bar "${URL}" -o "${ARCHIVE}" >&2
fi

tar -xzf "${ARCHIVE}" -C "${VENDOR_DIR}"

BIN="${VENDOR_DIR}/llama-swap"
chmod +x "${BIN}"
echo "==> Ready: ${BIN}" >&2
echo "${BIN}"
