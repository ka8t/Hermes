#!/usr/bin/env bash
# Builds (or refreshes) the "agent-template" Hermes profile used as the
# --clone-from source when provisioning a new per-user profile — see
# ../../shared/multi-user-agents.md and scripts/provision-user.sh.
#
# Re-running this script is the supported way to pick up changes to this
# repo's own config.yaml.example / skills/agent-creation: it always
# overwrites the template profile's config and skills with the current
# repo content, so the template never drifts from what's checked in.
#
# Docker-only (this repo's VPS default path). For the native VPS path,
# run the equivalent commands against your own hermes install directly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TEMPLATE_NAME="${AGENT_TEMPLATE_PROFILE:-agent-template}"
PROFILE_DIR="/opt/data/profiles/${TEMPLATE_NAME}"

if ! docker compose ps hermes --status running --quiet >/dev/null 2>&1 || \
   [ -z "$(docker compose ps hermes --status running --quiet 2>/dev/null)" ]; then
  echo "The 'hermes' container isn't running — start it first (docker compose up -d)." >&2
  exit 1
fi

if docker compose exec -T hermes test -d "${PROFILE_DIR}" 2>/dev/null; then
  echo "==> Profile '${TEMPLATE_NAME}' already exists — refreshing its config and skills"
else
  echo "==> Creating profile '${TEMPLATE_NAME}'"
  docker compose exec -T hermes hermes profile create "${TEMPLATE_NAME}"
fi

echo "==> Writing this repo's config.yaml.example into the template profile"
docker compose cp config/config.yaml.example "hermes:${PROFILE_DIR}/config.yaml"

echo "==> Seeding skills/agent-creation into the template profile"
docker compose exec -T hermes rm -rf "${PROFILE_DIR}/skills/ka8t-hermes/agent-creation"
docker compose exec -T hermes mkdir -p "${PROFILE_DIR}/skills/ka8t-hermes"
docker compose cp ../skills/agent-creation "hermes:${PROFILE_DIR}/skills/ka8t-hermes/agent-creation"

echo ""
echo "==> Template ready. Verify with:"
echo "  docker compose exec hermes hermes -p ${TEMPLATE_NAME} prompt-size"
echo "  docker compose exec hermes hermes -p ${TEMPLATE_NAME} config get model.default"
