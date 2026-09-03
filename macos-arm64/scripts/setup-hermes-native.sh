#!/usr/bin/env bash
# Seeds a native Hermes install (see install-hermes-native.sh) with this
# repo's config: point it at the native llama-swap endpoint, apply the
# enterprise-safe approvals default, and sync the bundled agent-creation
# skills — the same three things the Docker image
# (ghcr.io/ka8t/hermes, see ../../docker/) bakes in.
#
# Never overwrites an existing config.yaml/.env — same "seed only on first
# boot" rule Hermes's own Docker image follows, so re-running this after
# you've customized things is a safe no-op for those files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v hermes >/dev/null 2>&1; then
  echo "hermes not found on PATH — run ./scripts/install-hermes-native.sh first." >&2
  exit 1
fi

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "${HERMES_HOME}"

if [ ! -f "${HERMES_HOME}/config.yaml" ]; then
  cat > "${HERMES_HOME}/config.yaml" <<'YAML'
# Native install — llama-swap runs on this same machine, so it's reached
# over plain localhost, no host.docker.internal needed (that's only a
# Docker-networking workaround, irrelevant once Hermes itself is native).
model:
  default: llama-3.1-8b-instruct
  provider: custom
  base_url: http://127.0.0.1:8080/v1
  context_length: 65536

# Every dangerous action requires an explicit human answer — no silent
# auto-approval. See ../../shared/enterprise-safety.md.
approvals:
  mode: manual

# Hermes's default auxiliary-model routing tries free-tier external
# providers (OpenRouter, Nous Portal) before the main model for session
# titles — an outbound call this deployment has no credentials for, and
# one that contradicts "nothing leaves the server". See
# ../../shared/telegram-setup.md.
auxiliary:
  title_generation:
    enabled: false
YAML
  echo "==> ${HERMES_HOME}/config.yaml created"
else
  echo "==> ${HERMES_HOME}/config.yaml already exists — left untouched"
fi

if [ ! -f "${HERMES_HOME}/.env" ] && [ -f .env ]; then
  cp .env "${HERMES_HOME}/.env"
  echo "==> ${HERMES_HOME}/.env seeded from this directory's .env (Telegram, dashboard creds)"
elif [ -f "${HERMES_HOME}/.env" ]; then
  echo "==> ${HERMES_HOME}/.env already exists — left untouched"
else
  echo "!! No local .env found to seed from — copy .env.example to .env first (see README.md)" >&2
fi

echo "==> Syncing bundled skills (agent-creation) into ${HERMES_HOME}/skills/ka8t-hermes/"
mkdir -p "${HERMES_HOME}/skills/ka8t-hermes"
cp -R ../skills/agent-creation "${HERMES_HOME}/skills/ka8t-hermes/agent-creation"

echo ""
echo "Done. Next (if you haven't already set up ./data/models.yaml — same file"
echo "the Docker path uses, see README.md):"
echo "  1. ./scripts/download-model.sh"
echo "  2. mkdir -p data && cp config/models.yaml.example data/models.yaml"
echo "  3. ./scripts/run-llama-swap.sh                      # keep running — the model"
echo "  4. hermes gateway install && hermes gateway start   # Hermes as a launchd service"
echo "  5. hermes gateway setup                             # once, to wire up Telegram"
