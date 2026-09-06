#!/usr/bin/env bash
# Interactively configures the web dashboard's basic-auth credentials
# (issue #60, part of #59) — the one piece of #10's original
# credential-prompting scope that hermes-agent's own `hermes gateway setup`
# wizard does NOT cover (that wizard handles Telegram/WhatsApp/Teams
# platform credentials, not this repo's own dashboard).
#
# Callable standalone, or from provision.sh (#61) as part of the guided
# setup flow. Requires .env to already exist (provision.sh creates it from
# .env.example on first run) — this script only edits it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -f .env ]; then
  echo "!! .env not found — run ./provision.sh first (or copy .env.example yourself)." >&2
  exit 1
fi

# .env.example's own sentinel value — anything else means a real password
# has already been set, so this is a re-run, not first configuration.
PLACEHOLDER_PASSWORD="changeme-generate-a-real-password"

CURRENT_USERNAME="$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' .env | cut -d= -f2-)"
CURRENT_PASSWORD="$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=' .env | cut -d= -f2-)"

if [ -n "${CURRENT_PASSWORD}" ] && [ "${CURRENT_PASSWORD}" != "${PLACEHOLDER_PASSWORD}" ]; then
  echo "==> Dashboard credentials already configured (user: ${CURRENT_USERNAME})."
  read -r -p "    Reconfigure them? [y/N] " REPLY
  case "${REPLY}" in
    [yY]*) ;;
    *) echo "==> Keeping existing credentials."; exit 0 ;;
  esac
fi

echo ""
echo "The web dashboard (http://<vps-ip>:9119) needs a username and password"
echo "so it isn't wide open to anyone who can reach the port."
echo ""

read -r -p "Dashboard username [${CURRENT_USERNAME:-admin}]: " NEW_USERNAME
NEW_USERNAME="${NEW_USERNAME:-${CURRENT_USERNAME:-admin}}"

read -r -p "Generate a secure password automatically? [Y/n] " GEN_REPLY
case "${GEN_REPLY}" in
  [nN]*)
    read -r -s -p "Dashboard password: " NEW_PASSWORD
    echo ""
    if [ -z "${NEW_PASSWORD}" ]; then
      echo "!! Empty password not allowed." >&2
      exit 1
    fi
    ;;
  *)
    NEW_PASSWORD="$(openssl rand -base64 24)"
    echo "==> Generated password: ${NEW_PASSWORD}"
    echo "    (shown once — save it now, e.g. in a password manager)"
    ;;
esac

sed -i "s|^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=.*|HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${NEW_USERNAME}|" .env
sed -i "s|^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=.*|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${NEW_PASSWORD}|" .env

echo "==> Dashboard credentials written to .env."
