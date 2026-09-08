#!/usr/bin/env bash
# The guided macOS setup flow (issue #67, part of #65) — orchestrates the
# existing scripts in this directory instead of reimplementing them, only
# runs interactively (see the TTY check below; this script has no
# non-interactive/piped mode, unlike the VPS's provision.sh, since there's
# no curl-pipeable one-liner documented for macOS).
#
# No root/sudo needed anywhere here — Docker Desktop and the native
# installers are all user-level (opposite of the VPS's provision.sh).
# No GPU detection either — always Apple Silicon/Metal.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "!! This needs a real terminal to ask you questions — run it directly," >&2
  echo "!! not piped." >&2
  exit 1
fi

echo "==> Guided macOS setup. Each step explains itself before it runs — see"
echo "    README.md for the same steps done by hand, or shared/*.md docs for depth."
echo ""

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> .env created from .env.example."
fi

mkdir -p data
if [ ! -f data/config.yaml ]; then
  cp config/config.yaml.example data/config.yaml
  echo "==> data/config.yaml initialized from config/config.yaml.example"
fi
if [ ! -f data/models.yaml ]; then
  cp config/models.yaml.example data/models.yaml
  echo "==> data/models.yaml initialized from config/models.yaml.example"
fi

CURRENT_LLAMA_SERVER_BIN="$(grep -E '^LLAMA_SERVER_BIN=' .env | cut -d= -f2-)"

# -x alone (permission bits) doesn't catch macOS's "Optimize Mac Storage"
# (iCloud Drive) evicting this exact binary's content to 0 bytes while
# ls/stat still report its original size — confirmed live this session
# (see README.md's troubleshooting table). -s (non-empty) does. Try to
# re-materialize via brctl before falling back to a fresh download.
LLAMA_SERVER_BIN_USABLE=0
if [ -n "${CURRENT_LLAMA_SERVER_BIN}" ] && [ -x "${CURRENT_LLAMA_SERVER_BIN}" ]; then
  if [ -s "${CURRENT_LLAMA_SERVER_BIN}" ]; then
    LLAMA_SERVER_BIN_USABLE=1
  else
    echo "!! ${CURRENT_LLAMA_SERVER_BIN} exists and is executable but EMPTY"
    echo "!! (0 bytes) -- likely iCloud Drive eviction, not a real deletion."
    if command -v brctl >/dev/null 2>&1; then
      echo "==> Attempting to re-materialize via 'brctl download'..."
      brctl download "${CURRENT_LLAMA_SERVER_BIN}" >/dev/null 2>&1 || true
      sleep 2
    fi
    if [ -s "${CURRENT_LLAMA_SERVER_BIN}" ]; then
      echo "==> Recovered."
      LLAMA_SERVER_BIN_USABLE=1
    else
      echo "==> Still empty -- treating as missing, re-downloading below."
    fi
  fi
fi

if [ "${LLAMA_SERVER_BIN_USABLE}" = 1 ]; then
  echo "==> llama-server already resolved: ${CURRENT_LLAMA_SERVER_BIN}"
else
  echo ""
  echo "==> Downloading llama-server (the actual model-running binary, Metal-accelerated)."
  LLAMA_SERVER_BIN="$(./scripts/download-prebuilt-llama-server.sh | tail -n1)"
  sed -i '' "s|^LLAMA_SERVER_BIN=.*|LLAMA_SERVER_BIN=${LLAMA_SERVER_BIN}|" .env
  if ! grep -q '^LLAMA_SERVER_BIN=' .env; then
    printf '\nLLAMA_SERVER_BIN=%s\n' "${LLAMA_SERVER_BIN}" >> .env
  fi
  echo "==> LLAMA_SERVER_BIN set in .env: ${LLAMA_SERVER_BIN}"
fi

echo ""
echo "==> Downloading the default model (see ../shared/model-notes.md to change it)."
./scripts/download-model.sh

echo ""
echo "==> Dashboard credentials protect the web UI (http://127.0.0.1:9119) from"
echo "    anyone else on your network."
./scripts/configure-env.sh

LLAMA_PORT="$(grep -E '^LLAMA_PORT=' .env | cut -d= -f2-)"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_PID_FILE="$(pwd)/.llama-swap.pid"
if curl -sf "http://127.0.0.1:${LLAMA_PORT}/health" >/dev/null 2>&1; then
  echo ""
  echo "==> llama-swap already running on port ${LLAMA_PORT} (started some other"
  echo "    way — a prior run of this script, launchd, or manually) — skipping."
else
  echo ""
  echo "==> Starting llama-swap + llama-server in the background (logs:"
  echo "    macos-arm64/llama-swap.log). This is a plain background process, not"
  echo "    a persistent service — it stops when you log out. See README.md,"
  echo "    \"Running llama-swap in the background\", to install it as a launchd"
  echo "    service instead (needs a one-time Full Disk Access grant if this repo"
  echo "    lives under ~/Documents — see that section for why)."
  nohup ./scripts/run-llama-swap.sh > llama-swap.log 2>&1 &
  echo $! > "${LLAMA_PID_FILE}"
  echo "==> Waiting for llama-swap to respond..."
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${LLAMA_PORT}/health" >/dev/null 2>&1; then
      echo "==> llama-swap is up."
      break
    fi
    sleep 2
  done
fi

echo ""
read -r -p "Run Hermes in Docker, or fully native (no Docker)? [docker/native, default docker] " HERMES_MODE_CHOICE
HERMES_MODE_CHOICE="${HERMES_MODE_CHOICE:-docker}"

case "${HERMES_MODE_CHOICE}" in
  native)
    echo ""
    echo "==> Installing Hermes natively."
    ./scripts/install-hermes-native.sh
    ./scripts/setup-hermes-native.sh
    ./scripts/patch-native-hermes.sh
    GATEWAY_SETUP_CMD="hermes gateway setup"
    VERIFY_CMD="./scripts/verify-inference.sh"
    ;;
  *)
    echo ""
    echo "==> Starting Hermes in Docker."
    # Found live, 2026-09-07: starting the container right after writing
    # .env (configure-env.sh, just above) can hit a real Docker Desktop
    # bind-mount race on macOS — the container's own dotenv read can raise
    # "OSError: [Errno 35] Resource deadlock avoided" if .env was modified
    # only moments earlier. A short pause after flushing to disk avoids it;
    # waiting on a stable, untouched .env for even a couple seconds never
    # reproduced the crash in testing.
    sync
    sleep 2
    docker compose up -d
    GATEWAY_SETUP_CMD="docker compose exec hermes hermes gateway setup"
    VERIFY_CMD="./scripts/verify-inference.sh"
    ;;
esac

echo ""
read -r -p "Connect Telegram now (hermes gateway setup)? [Y/n] " TELEGRAM_REPLY
case "${TELEGRAM_REPLY}" in
  [nN]*) ;;
  *)
    GATEWAY_SETUP_CMD="${GATEWAY_SETUP_CMD}" ./scripts/configure-telegram.sh
    if [ "${HERMES_MODE_CHOICE}" != "native" ]; then
      # Docker mode only: `hermes gateway setup`'s own "restart to pick up
      # changes?" prompt only knows systemd/launchd (see its source,
      # confirmed live 2026-09-08) — it does nothing useful inside this
      # container, and a plain in-container `hermes gateway restart`
      # wouldn't help anyway, since Docker fixes a container's env vars at
      # creation time (../shared/telegram-setup.md, "Apply the
      # credentials"). Recreate the container so the token just written to
      # .env is actually the one in use — otherwise the guided demo below
      # queries a gateway still running with the old (or no) token, with
      # no visible error explaining why.
      echo ""
      echo "==> Recreating the container so it picks up the Telegram config"
      echo "    just written to .env (Docker only reads it at creation)."
      sync
      sleep 2
      docker compose up -d
    fi
    ;;
esac

echo ""
read -r -p "Run the mandatory real-inference-throughput check now? [Y/n] " VERIFY_REPLY
case "${VERIFY_REPLY}" in
  [nN]*) ;;
  *)
    echo "==> Hardware specs alone don't predict real speed — this measures it"
    echo "    directly. See ../shared/hardware-sizing.md."
    eval "${VERIFY_CMD}"
    ;;
esac

echo ""
if launchctl list 2>/dev/null | grep -q com.hermes.silent-failure-watchdog; then
  echo "==> Silent-failure watchdog already installed — skipping."
else
  read -r -p "Install the silent-failure watchdog (recommended, issue #56)? [Y/n] " WATCHDOG_REPLY
  case "${WATCHDOG_REPLY}" in
    [nN]*) ;;
    *)
      echo "==> hermes-agent's own tool-calling loop can occasionally leave a"
      echo "    message with no reply at all. This installs a periodic check that"
      echo "    notices and tells the affected user."
      echo "!! Known limitation: if this repo lives under ~/Documents (or"
      echo "!! ~/Desktop, ~/Downloads), macOS blocks the background job until you"
      echo "!! grant /bin/bash Full Disk Access — System Settings > Privacy &"
      echo "!! Security > Full Disk Access. See README.md's \"Silent-failure"
      echo "!! watchdog\" section for the exact steps if this fails silently."
      # The plist template's paths already include a literal "macos-arm64/"
      # segment (it's written for someone hand-copying the repo root from
      # the README), but this script already cd'd into macos-arm64/ itself
      # (see REPO_DIR above) — so REPO_PATH here must be the repo root, one
      # level up from $(pwd), not $(pwd) itself. Using $(pwd) doubled the
      # segment into .../macos-arm64/macos-arm64/... in every installed
      # path (ProgramArguments, WorkingDirectory, StandardOut/ErrorPath),
      # so the watchdog silently never ran. Found live, 2026-09-08.
      REPO_PATH="$(dirname "$(pwd)")"
      sed "s|REPLACE_WITH_REPO_PATH|${REPO_PATH}|g" scripts/com.hermes.silent-failure-watchdog.plist.example \
        > ~/Library/LaunchAgents/com.hermes.silent-failure-watchdog.plist
      launchctl load ~/Library/LaunchAgents/com.hermes.silent-failure-watchdog.plist
      echo "==> Watchdog LaunchAgent loaded (check the Full Disk Access note above"
      echo "    if it doesn't actually run)."
      ;;
  esac
fi

HERMES_RUN_MODE="${HERMES_MODE_CHOICE}" ./scripts/guided-demo.sh
