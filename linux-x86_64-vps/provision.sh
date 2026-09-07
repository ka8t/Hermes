#!/usr/bin/env bash
# Provisions a fresh Ubuntu 22.04+/x86-64 VPS for this stack
# (llama-swap + llama.cpp + Hermes Agent, all three in Docker).
#
# Run this once, as root, on the VPS:
#   curl -fsSL https://raw.githubusercontent.com/ka8t/Hermes/main/linux-x86_64-vps/provision.sh | bash
# or, once the repository is cloned on the VPS:
#   cd linux-x86_64-vps && ./provision.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "==> Installing Docker Engine + Compose plugin (if missing)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y docker-compose-plugin
fi

echo "==> Checking for a GPU (issue #13, any vendor)"
GPU_VENDOR=""
if command -v nvidia-smi >/dev/null 2>&1 || [ -e /dev/nvidia0 ]; then
  GPU_VENDOR="nvidia"
elif command -v rocm-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then
  GPU_VENDOR="amd"
elif command -v lspci >/dev/null 2>&1 && lspci | grep -iE "vga|3d|display" | grep -iq intel; then
  GPU_VENDOR="intel"
fi

if [ -n "${GPU_VENDOR}" ]; then
  echo "!! ${GPU_VENDOR} GPU detected — this script still provisions the"
  echo "!! CPU-only path by default. See ../shared/gpu-setup.md to switch to"
  echo "!! the ${GPU_VENDOR}-specific image/config instead (not done"
  echo "!! automatically — GPU support needs host-level prerequisites this"
  echo "!! script does not install for you)."
else
  echo "==> No GPU detected — proceeding with the CPU-only path (default)."
fi

echo "==> Preparing persistent directories"
mkdir -p data models

if [ ! -f .env ]; then
  cp .env.example .env
  echo "!! .env created from .env.example — edit it (Telegram token, etc.) before continuing."

  # .env.example's LLAMA_THREADS=2 is a conservative default sized for the
  # smallest documented reference VPS (2 vCPU) — auto-detect this box's
  # real core count instead of silently leaving it under-provisioned, since
  # llama.cpp's prefill/generation throughput scales close to linearly with
  # thread count. Leaves one core for the OS/Docker/Hermes overhead.
  DETECTED_CORES="$(nproc)"
  if [ "${DETECTED_CORES}" -gt 2 ]; then
    LLAMA_THREADS="$((DETECTED_CORES - 1))"
    sed -i "s/^LLAMA_THREADS=.*/LLAMA_THREADS=${LLAMA_THREADS}/" .env
    echo "==> Detected ${DETECTED_CORES} vCPUs — set LLAMA_THREADS=${LLAMA_THREADS} in .env"
  fi
fi

if [ ! -f data/config.yaml ]; then
  cp config/config.yaml.example data/config.yaml
  echo "==> data/config.yaml initialized from config/config.yaml.example"
fi

if [ ! -f data/models.yaml ]; then
  cp config/models.yaml.example data/models.yaml
  echo "==> data/models.yaml initialized from config/models.yaml.example"
fi

MODEL_FILE="$(grep -E '^MODEL_FILE=' .env | cut -d= -f2)"
MODEL_FILE="${MODEL_FILE:-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf}"
MODEL_REPO="$(grep -E '^MODEL_REPO=' .env | cut -d= -f2)"
MODEL_REPO="${MODEL_REPO:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF}"

if [ ! -f "models/${MODEL_FILE}" ]; then
  echo "==> Downloading model ${MODEL_FILE} (see ../shared/model-notes.md to change models)"
  curl -fL --progress-bar \
    "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
    -o "models/${MODEL_FILE}"
else
  echo "==> Model already present: models/${MODEL_FILE}"
fi

echo ""
echo "Provisioning done. Remaining steps:"
echo "  1. Edit .env (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, and"
echo "     HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD — see ../shared/telegram-setup.md)"
echo "  2. docker compose up -d"
echo "  3. docker compose logs -f llama-swap   # wait for it to report healthy"
echo "  4. docker compose exec hermes hermes gateway setup   # once, for Telegram"

# Everything below is interactive-only (issue #61, part of #59) — orchestrates
# the remaining steps this script has always printed above instead of just
# describing them. Left OFF entirely when this script is piped (e.g. the
# documented `curl -fsSL .../provision.sh | bash` one-liner), since stdin
# isn't a terminal to prompt against there and the printed instructions above
# are the only sane output for that path — unchanged from before this issue.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  exit 0
fi

echo ""
read -r -p "Continue with guided setup now (dashboard credentials, start Hermes, connect Telegram)? [Y/n] " CONTINUE_REPLY
case "${CONTINUE_REPLY}" in
  [nN]*) exit 0 ;;
esac

echo ""
echo "==> Dashboard credentials protect the web UI (http://<vps-ip>:9119) from"
echo "    anyone who can reach the port."
./scripts/configure-env.sh

echo ""
echo "==> Starting Hermes and llama-swap."
docker compose up -d

echo ""
echo "==> Waiting for llama-swap to report healthy (loads the model into memory —"
echo "    can take a minute or two, but is NOT the slow part; that's the first reply)."
for _ in $(seq 1 60); do
  STATUS="$(docker compose ps --format '{{.Health}}' llama-swap 2>/dev/null || true)"
  if [ "${STATUS}" = "healthy" ]; then
    echo "==> llama-swap is healthy."
    break
  fi
  sleep 5
done

echo ""
read -r -p "Connect Telegram now (hermes gateway setup)? [Y/n] " TELEGRAM_REPLY
case "${TELEGRAM_REPLY}" in
  [nN]*) ;;
  *)
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
    docker compose exec hermes hermes gateway setup
    ;;
esac

echo ""
read -r -p "Run the mandatory real-inference-throughput check now? [Y/n] " VERIFY_REPLY
case "${VERIFY_REPLY}" in
  [nN]*) ;;
  *)
    echo "==> Hardware specs alone don't predict real speed — this measures it"
    echo "    directly against this exact deployment. See ../shared/hardware-sizing.md."
    ./scripts/verify-inference.sh
    ;;
esac

echo ""
if systemctl is-enabled silent-failure-watchdog.timer >/dev/null 2>&1; then
  echo "==> Silent-failure watchdog already installed and enabled — skipping."
else
  read -r -p "Install the silent-failure watchdog (recommended, issue #56)? [Y/n] " WATCHDOG_REPLY
  case "${WATCHDOG_REPLY}" in
    [nN]*) ;;
    *)
      echo "==> hermes-agent's own tool-calling loop can occasionally leave a"
      echo "    message with no reply at all. This runs a periodic check that"
      echo "    notices and tells the affected user, instead of leaving them"
      echo "    guessing whether anything went wrong."
      REPO_PATH="$(cd .. && pwd)/linux-x86_64-vps"
      sed "s|REPLACE_WITH_REPO_PATH|${REPO_PATH}|g" scripts/silent-failure-watchdog.service.example \
        > /etc/systemd/system/silent-failure-watchdog.service
      cp scripts/silent-failure-watchdog.timer.example /etc/systemd/system/silent-failure-watchdog.timer
      systemctl daemon-reload
      systemctl enable --now silent-failure-watchdog.timer
      echo "==> Watchdog installed and running."
      ;;
  esac
fi

./scripts/guided-demo.sh
