#!/usr/bin/env bash
# Onboards a new user onto their own isolated Hermes profile, routed from
# the one shared bot token via gateway.multiplex_profiles +
# gateway.profile_routes. See ../../shared/multi-user-agents.md.
#
# Usage: ./provision-user.sh <platform> <chat_id> <profile-slug>
# Example: ./provision-user.sh telegram 987654321 alice
#
# In a Telegram DM, chat_id equals the sender's numeric user_id (get it
# via @userinfobot — see ../../shared/telegram-setup.md).
#
# Idempotent: safe to re-run for the same user (no-op if the route already
# exists), and refuses (rather than silently overwriting) if that
# platform+chat_id is already routed to a *different* profile.
#
# Does NOT decide who is allowed to talk to the bot at all — that's
# TELEGRAM_ALLOWED_USERS / `hermes pairing approve`, a human decision made
# before this script ever runs. This only wires up the profile + route for
# someone already allowed in.
#
# Docker-only (this repo's VPS default path).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ $# -ne 3 ]; then
  echo "Usage: $0 <platform> <chat_id> <profile-slug>" >&2
  echo "Example: $0 telegram 987654321 alice" >&2
  exit 1
fi

PLATFORM="$1"
CHAT_ID="$2"
SLUG="$3"
TEMPLATE_NAME="${AGENT_TEMPLATE_PROFILE:-agent-template}"
PROFILE_DIR="/opt/data/profiles/${SLUG}"

if [ -z "$(docker compose ps hermes --status running --quiet 2>/dev/null)" ]; then
  echo "The 'hermes' container isn't running — start it first (docker compose up -d)." >&2
  exit 1
fi

if ! docker compose exec -T hermes test -d "/opt/data/profiles/${TEMPLATE_NAME}" 2>/dev/null; then
  echo "Template profile '${TEMPLATE_NAME}' not found — run ./scripts/build-agent-template.sh first." >&2
  exit 1
fi

# Validate/prepare the route BEFORE creating anything — a rejected or
# no-op route must never leave an orphaned profile behind.
echo "==> Reading the default profile's config.yaml"
TMP_CONFIG="$(mktemp)"
trap 'rm -f "${TMP_CONFIG}"' EXIT
docker compose cp hermes:/opt/data/config.yaml "${TMP_CONFIG}"

set +e
python3 - "${TMP_CONFIG}" "${PLATFORM}" "${CHAT_ID}" "${SLUG}" <<'PY'
import sys, yaml

path, platform, chat_id, slug = sys.argv[1:5]

with open(path) as f:
    raw = f.read()

# Hermes appends a trailing pure-comment documentation block to a
# generated config.yaml. PyYAML carries no data for it, so a naive
# load+dump would silently drop it — split it off and re-append verbatim.
marker = "\n# ──"
split_at = raw.find(marker)
if split_at == -1:
    yaml_part, tail = raw, ""
else:
    yaml_part, tail = raw[:split_at], raw[split_at:]

data = yaml.safe_load(yaml_part) or {}

gateway = data.setdefault("gateway", {})
gateway["multiplex_profiles"] = True
routes = gateway.setdefault("profile_routes", [])

for r in routes:
    if str(r.get("platform")) == platform and str(r.get("chat_id")) == str(chat_id):
        if r.get("profile") == slug:
            print(f"==> Route already exists: {platform}:{chat_id} -> {slug} (no change)")
            sys.exit(3)
        print(
            f"ERROR: {platform}:{chat_id} is already routed to profile "
            f"'{r.get('profile')}', not '{slug}'. Refusing to overwrite — "
            "edit that route by hand first if this is intentional.",
            file=sys.stderr,
        )
        sys.exit(1)

routes.append({
    "name": f"{slug}-route",
    "platform": platform,
    "chat_id": str(chat_id),
    "profile": slug,
})

with open(path, "w") as f:
    f.write(yaml.safe_dump(data, default_flow_style=False, sort_keys=False) + tail)

print(f"==> Route added: {platform}:{chat_id} -> {slug}")
PY
PY_STATUS=$?
set -e

if [ "${PY_STATUS}" -eq 1 ]; then
  exit 1
fi

PROFILE_CREATED=0
if docker compose exec -T hermes test -d "${PROFILE_DIR}" 2>/dev/null; then
  echo "==> Profile '${SLUG}' already exists — skipping creation"
else
  echo "==> Creating profile '${SLUG}' from '${TEMPLATE_NAME}'"
  docker compose exec -T hermes hermes profile create "${SLUG}" --clone-from "${TEMPLATE_NAME}"
  PROFILE_CREATED=1
fi

if [ "${PY_STATUS}" -eq 3 ] && [ "${PROFILE_CREATED}" -eq 0 ]; then
  echo "==> No config change needed, skipping gateway restart"
else
  if [ "${PY_STATUS}" -eq 0 ]; then
    echo "==> Writing the updated config.yaml back into the container"
    docker compose cp "${TMP_CONFIG}" hermes:/opt/data/config.yaml
  fi
  echo "==> Restarting the gateway to pick up the new profile/route"
  docker compose up -d --force-recreate hermes
fi

echo ""
echo "==> Done. Verify with:"
echo "  docker compose logs --since 1m hermes | grep -i telegram"
echo "  docker compose exec hermes hermes -p ${SLUG} config get model.default"
