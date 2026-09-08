#!/usr/bin/env bash
# Gate + guide for connecting Telegram (issue #10's "re-runnable, offers to
# update specific values, never silently clobbers" acceptance criterion).
# Mirrors configure-env.sh's "already configured, reconfigure?" pattern —
# TELEGRAM_BOT_TOKEN/TELEGRAM_ALLOWED_USERS live in this same project .env
# (see ../../shared/single-env-file.md), but until now provision.sh never
# read them back before re-running `hermes gateway setup` on an
# already-configured deployment.
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

# .env.example's own sentinel values — anything else means Telegram has
# already been configured, so this is a re-run, not first setup.
PLACEHOLDER_TOKEN="changeme:ABCdefGHIjklMNOpqrSTUvwxYZ"
PLACEHOLDER_USERS="000000000"

CURRENT_TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2-)"
CURRENT_USERS="$(grep -E '^TELEGRAM_ALLOWED_USERS=' .env | cut -d= -f2-)"

if [ -n "${CURRENT_TOKEN}" ] && [ "${CURRENT_TOKEN}" != "${PLACEHOLDER_TOKEN}" ]; then
  # Masked, not shown in full — a bot token is a live credential, and this
  # runs in a plain terminal (scrollback, screen recordings, CI logs).
  MASKED_TOKEN="...${CURRENT_TOKEN: -4}"

  # Never trust "a non-placeholder string is in .env" as proof the bot
  # still works — found live, 2026-09-08: deleting a bot via BotFather's
  # /deletebot leaves its old (now-dead) token sitting in .env, and the
  # previous version of this check would offer "Reconfigure? [y/N]"
  # defaulting to N — pressing Enter silently kept a dead token and the
  # gateway would fail with no clear signal why. Ask Telegram directly
  # instead of guessing.
  echo "==> Checking whether the configured bot (token ending ${MASKED_TOKEN}) still responds..."
  GETME_RESPONSE="$(curl -s --max-time 10 "https://api.telegram.org/bot${CURRENT_TOKEN}/getMe" || true)"

  if printf '%s' "${GETME_RESPONSE}" | grep -q '"ok":true'; then
    echo "==> Telegram already configured and working (token ending ${MASKED_TOKEN}, allowed users: ${CURRENT_USERS:-none})."
    read -r -p "    Reconfigure it anyway? [y/N] " REPLY
    case "${REPLY}" in
      [yY]*) ;;
      *) echo "==> Keeping existing Telegram configuration."; exit 0 ;;
    esac
  elif [ -n "${GETME_RESPONSE}" ]; then
    # Telegram answered, but rejected the token outright (401 Unauthorized
    # for a deleted/revoked bot) — never worth silently keeping, so there's
    # no y/N here: go straight to setting up a new one.
    echo "!! The configured token no longer works: ${GETME_RESPONSE}"
    echo "==> Setting up a new bot."
  else
    # curl itself failed (offline, DNS, timeout) — can't tell if the token
    # is actually fine, so don't assume it's dead. Ask, but say plainly
    # that this hasn't been verified.
    echo "!! Couldn't reach api.telegram.org to verify the current token (network issue?)."
    echo "==> Telegram already configured (token ending ${MASKED_TOKEN}, allowed users: ${CURRENT_USERS:-none}) — unverified."
    read -r -p "    Reconfigure it? [y/N] " REPLY
    case "${REPLY}" in
      [yY]*) ;;
      *) echo "==> Keeping existing Telegram configuration (unverified)."; exit 0 ;;
    esac
  fi
fi

echo ""
echo "==> This is hermes-agent's own setup wizard. It offers two ways to"
echo "    connect Telegram — you'll see both as an on-screen choice:"
echo ""
echo "    [1] Automatic (QR code) — scan it, confirm in Telegram, done. Fast,"
echo "        but the bot is created through a Nous Research-hosted service"
echo "        (setup.hermes-agent.nousresearch.com), not one you make/own"
echo "        yourself — a real third-party dependency this repo doesn't use"
echo "        anywhere else (found live, 2026-09-07, not verified end-to-end)."
echo "    [2] Manual (BotFather) — a few more steps, but you create and fully"
echo "        own the bot, no third party involved. Everything you need for"
echo "        this option, so you don't have to leave this terminal:"
echo ""
echo "        1. Open Telegram, search for @BotFather, send: /newbot"
echo "        2. Give it a display name, then a username ending in 'bot'"
echo "           (e.g. my-hermes-bot)"
echo "        3. BotFather replies with a token like:"
echo "           123456789:ABCdefGHIjklMNOpqrSTUvwxYZ"
echo "           — that's what the wizard asks for as your bot token."
echo "        4. Search for @userinfobot on Telegram, send it any message."
echo "           It replies with a numeric Id — that's your own Telegram"
echo "           user ID, what the wizard asks for as the allowed user."
echo "           (Don't confuse the two — the bot's own name/username is"
echo "           never your user ID.)"
echo ""
echo "        Can't find your bot after creating it? Search indexing can"
echo "        lag — use https://t.me/<username> directly, or confirm the"
echo "        exact username with:"
echo "          curl -s \"https://api.telegram.org/bot<TOKEN>/getMe\""
echo ""
echo "    Full reference (optional channels, groups, more troubleshooting):"
echo "    ../shared/telegram-setup.md"
echo ""
eval "${GATEWAY_SETUP_CMD}"
