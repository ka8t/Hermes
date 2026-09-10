#!/usr/bin/env bash
# Gate + guide for connecting email (issue #89) — mirrors
# configure-telegram.sh's "re-runnable, offers to update specific values,
# never silently clobbers" pattern. EMAIL_ADDRESS/EMAIL_PASSWORD/etc. live
# in this same project .env (see ../../shared/single-env-file.md).
#
# Unlike Telegram, there's no equivalent of BotFather's /deletebot to
# detect a dead credential from here (an app password doesn't expire the
# same visible way) — `hermes gateway setup` does its own connectivity
# check against the real IMAP/SMTP servers when you actually configure
# it, which this script can't replicate without live credentials.
#
# Requires GATEWAY_SETUP_CMD in the environment (set by provision.sh).
# Requires .env to already exist.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${GATEWAY_SETUP_CMD:?GATEWAY_SETUP_CMD must be set (e.g. by provision.sh)}"

if [ ! -f .env ]; then
  echo "!! .env not found — run ./provision.sh first (or copy .env.example yourself)." >&2
  exit 1
fi

CURRENT_ADDRESS="$(grep -E '^EMAIL_ADDRESS=' .env | cut -d= -f2-)"

if [ -n "${CURRENT_ADDRESS}" ]; then
  echo "==> Email already configured (address: ${CURRENT_ADDRESS})."
  read -r -p "    Reconfigure it? [y/N] " REPLY
  case "${REPLY}" in
    [yY]*) ;;
    *) echo "==> Keeping existing email configuration."; exit 0 ;;
  esac
fi

echo ""
echo "==> This is hermes-agent's own setup wizard — pick \"Email\" from the"
echo "    platform menu when it appears. You'll need:"
echo ""
echo "    1. A mailbox to use (a dedicated one for the agent, not your"
echo "       personal inbox, is strongly recommended — its password lives"
echo "       in plain text in .env)."
echo "    2. An app-specific password, not the account's real login"
echo "       password. For Gmail: enable 2-Step Verification, then"
echo "       Google Account -> Security -> 2-Step Verification -> App"
echo "       passwords. Other providers: check their docs for \"app"
echo "       password\" or \"IMAP/SMTP access\"."
echo "    3. IMAP/SMTP host + port. Gmail: imap.gmail.com:993,"
echo "       smtp.gmail.com:587 (both defaults). Other providers vary."
echo "    4. Which sender address(es) are allowed to message the agent"
echo "       (EMAIL_ALLOWED_USERS) — an inbound-email agent with no"
echo "       allow-list acts on mail from anyone who learns its address."
echo ""
echo "    Full reference: ../shared/email-setup.md"
echo ""
eval "${GATEWAY_SETUP_CMD}"

# Docker fixes a container's environment variables at creation time
# (../shared/telegram-setup.md) -- same reasoning as
# configure-telegram.sh's own recreate step, and same check: only
# matters when GATEWAY_SETUP_CMD actually runs inside a container
# (Docker mode) -- native mode's `hermes gateway setup` reads .env
# directly, no container env to go stale. Without this in Docker mode,
# the gateway process running right now never sees the credentials the
# wizard just wrote to .env.
case "${GATEWAY_SETUP_CMD}" in
  *"docker compose"*)
    echo ""
    echo "==> Recreating the container so it picks up the email config just"
    echo "    written to .env (Docker only reads it at creation)."
    docker compose up -d
    ;;
esac
