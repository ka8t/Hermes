#!/usr/bin/env bash
# Downloads the latest official prebuilt llama.cpp binary for Linux
# x86-64 (CPU only) into ./vendor/llama.cpp-prebuilt. Mirrors
# ../../macos-arm64/scripts/download-prebuilt-llama-server.sh — see
# ../../shared/prebuilt-binaries.md for what's actually inside it and why
# this deployment stopped getting llama-server via the
# ghcr.io/mostlygeek/llama-swap:cpu image (2026-09-15, issue #101: that
# image has its own, separate update lifecycle nothing in this repo was
# tracking, so the VPS silently ran a two-week-stale llama-server for
# a real incident's duration).
# Prints the path to the extracted llama-server binary on stdout.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VENDOR_DIR="$(pwd)/vendor/llama.cpp-prebuilt"
mkdir -p "${VENDOR_DIR}"

ASSET_PATTERN="bin-ubuntu-x64.tar.gz"

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
