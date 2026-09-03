#!/usr/bin/env bash
# Native (no-Docker) alternative to the hermes container: installs Hermes
# Agent directly on this Mac via the official installer. See README.md,
# "Native alternative (no Docker at all)".
# Idempotent: does nothing if `hermes` is already on PATH.
set -euo pipefail

if command -v hermes >/dev/null 2>&1; then
  echo "==> hermes already installed: $(command -v hermes)"
  hermes --version 2>&1 | head -1
  exit 0
fi

echo "==> Installing Hermes Agent natively (official installer)"
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

echo "==> Installed: $(command -v hermes)"
echo "HERMES_HOME defaults to ~/.hermes — see ./scripts/setup-hermes-native.sh next."
