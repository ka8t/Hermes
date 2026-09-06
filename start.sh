#!/usr/bin/env bash
# The recommended first thing to run after cloning this repo (issue #62,
# part of #59). Detects your platform and hands off to the right guided
# path — you shouldn't need to read multiple READMEs just to get started.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

OS="$(uname -s)"

case "$OS" in
  Linux)
    echo "==> Detected Linux — continuing with the guided VPS setup."
    echo ""
    if [ "$(id -u)" -ne 0 ]; then
      echo "!! This needs to run as root (it installs Docker and system packages)." >&2
      echo "!! Try: sudo ./start.sh" >&2
      exit 1
    fi
    exec ./linux-x86_64-vps/provision.sh
    ;;
  Darwin)
    echo "==> Detected macOS."
    echo ""
    echo "The guided, explained setup for macOS isn't built yet (issue #59) —"
    echo "for now, see macos-arm64/README.md for the manual installation steps."
    exit 0
    ;;
  *)
    echo "!! Unrecognized platform: ${OS}." >&2
    echo "!! This repo supports macOS (Apple Silicon) and Linux x86-64 — see" >&2
    echo "!! macos-arm64/README.md or linux-x86_64-vps/README.md directly." >&2
    exit 1
    ;;
esac
