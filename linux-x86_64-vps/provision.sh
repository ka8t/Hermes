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

# Issue #96: RAM was detected nowhere before this — a box below
# hardware-sizing.md's own documented thresholds (~14GB PASS/~12GB FAIL
# for the default model's footprint at this repo's 65536-token context)
# would only find out after downloading the model and running the
# mandatory verify-inference.sh check later. A heads-up before that
# download (~4.7GB) starts is cheap; it doesn't change what gets
# installed (no lighter verified alternative exists today, see
# ../shared/model-selection-guide.md's own "not a real option yet"
# section) but it means "why is this slow/OOMing" isn't a surprise.
TOTAL_RAM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${TOTAL_RAM_GB}" -gt 0 ]; then
  echo "==> Detected ${TOTAL_RAM_GB}GB RAM."
  if [ "${TOTAL_RAM_GB}" -lt 12 ]; then
    echo "!! Below this repo's documented FAIL threshold (~12GB) for the"
    echo "!! default model at its 65536-token context — see"
    echo "!! ../shared/hardware-sizing.md's RAM/disk table and"
    echo "!! ../shared/model-selection-guide.md before continuing. No"
    echo "!! lighter verified alternative exists today; this will likely"
    echo "!! swap or OOM, not just run slowly."
  elif [ "${TOTAL_RAM_GB}" -lt 14 ]; then
    echo "!! Below this repo's documented PASS threshold (~14GB), above"
    echo "!! FAIL — usable but tight. See ../shared/hardware-sizing.md."
  fi
else
  echo "!! Could not detect total RAM from /proc/meminfo — skipping the"
  echo "!! heads-up check. See ../shared/hardware-sizing.md and"
  echo "!! ../shared/model-selection-guide.md to check manually."
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

# Single .env file (issue #73): make data/.env a symlink to .env.real (which
# docker-compose.yml bind-mounts from this directory's own .env) BEFORE the
# first container boot, so hermes-agent's own first-boot seed step never
# creates a separate real file there. Must happen before `docker compose up
# -d` below — once the container has booted with a real file at that path,
# fixing it needs live surgery inside the running container instead (see
# ../shared/single-env-file.md for that recovery procedure and why a plain
# bind-mount of .env itself doesn't work on native Linux Docker).
if [ -L data/.env ]; then
  : # already set up correctly, nothing to do
elif [ -f data/.env ]; then
  echo "!! data/.env already exists as a REGULAR file (from a deployment"
  echo "   provisioned before this fix) — left untouched to avoid discarding"
  echo "   anything it holds that isn't in this directory's .env. See"
  echo "   ../shared/single-env-file.md for how to switch it to the"
  echo "   single-file setup on a running container."
else
  ln -s .env.real data/.env
  echo "==> data/.env symlinked to .env.real (this directory's own .env, via"
  echo "    docker-compose.yml's bind-mount) — one file, no more syncing needed"
fi

MODEL_FILE="$(grep -E '^MODEL_FILE=' .env | cut -d= -f2)"
MODEL_FILE="${MODEL_FILE:-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf}"
MODEL_REPO="$(grep -E '^MODEL_REPO=' .env | cut -d= -f2)"
MODEL_REPO="${MODEL_REPO:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF}"

MODEL_PATH="models/${MODEL_FILE}"
# -f alone doesn't guarantee a *complete* download -- an interrupted curl
# (SSH drop, disk full) used to be able to leave a truncated file directly
# at this final path, which a later run would then trust as "already
# present" forever. -s (non-empty) catches the worst case (0 bytes); the
# .part-then-rename below prevents a partial file from ever landing at
# the final path in the first place, on this run or any future one.
if [ -f "${MODEL_PATH}" ] && [ ! -s "${MODEL_PATH}" ]; then
  echo "!! ${MODEL_PATH} exists but is empty (0 bytes) -- an earlier"
  echo "!! download likely didn't finish. Re-downloading."
  rm -f "${MODEL_PATH}"
fi

if [ ! -f "${MODEL_PATH}" ]; then
  echo "==> Downloading model ${MODEL_FILE} (see ../shared/model-notes.md to change models)"
  curl -fL --progress-bar \
    "https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}" \
    -o "${MODEL_PATH}.part"
  mv "${MODEL_PATH}.part" "${MODEL_PATH}"
else
  echo "==> Model already present: ${MODEL_PATH}"
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
GATEWAY_SETUP_CMD="docker compose exec hermes hermes gateway setup"
VERIFY_CMD="./scripts/verify-inference.sh"

echo ""
read -r -p "Connect Telegram now (hermes gateway setup)? [Y/n] " TELEGRAM_REPLY
case "${TELEGRAM_REPLY}" in
  [nN]*) ;;
  *)
    GATEWAY_SETUP_CMD="${GATEWAY_SETUP_CMD}" ./scripts/configure-telegram.sh
    # `hermes gateway setup`'s own "restart to pick up changes?" prompt
    # only knows systemd/launchd (confirmed live 2026-09-08, reading
    # gateway_setup()'s source) — it does nothing useful inside this
    # container, and a plain in-container `hermes gateway restart`
    # wouldn't help anyway, since Docker fixes a container's env vars at
    # creation time (../shared/telegram-setup.md, "Apply the
    # credentials"). Recreate the container so the token just written to
    # .env is actually the one in use — otherwise the guided demo below
    # queries a gateway still running with the old (or no) token, with no
    # visible error explaining why.
    echo ""
    echo "==> Recreating the container so it picks up the Telegram config"
    echo "    just written to .env (Docker only reads it at creation)."
    docker compose up -d
    ;;
esac

echo ""
read -r -p "Also connect email now (hermes gateway setup, issue #89)? [y/N] " EMAIL_REPLY
case "${EMAIL_REPLY}" in
  [yY]*)
    GATEWAY_SETUP_CMD="${GATEWAY_SETUP_CMD}" ./scripts/configure-email.sh
    ;;
  *) ;;
esac

echo ""
read -r -p "Run the mandatory real-inference-throughput check now? [Y/n] " VERIFY_REPLY
case "${VERIFY_REPLY}" in
  [nN]*) ;;
  *)
    echo "==> Hardware specs alone don't predict real speed — this measures it"
    echo "    directly against this exact deployment. See ../shared/hardware-sizing.md."
    eval "${VERIFY_CMD}"
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
      # Issue #85: the watchdog above is itself a single point of failure
      # for #56's whole safety net (found live, 2026-09-10 — a blank
      # TELEGRAM_BOT_TOKEN made it fail silently for ~35 minutes). These
      # three pieces make that failure visible instead: an immediate
      # `wall` broadcast (OnFailure=, wired into the .service file above)
      # plus a persistent SSH login banner for as long as the failure
      # lasts.
      sed "s|REPLACE_WITH_REPO_PATH|${REPO_PATH}|g" scripts/silent-failure-watchdog-alert.service.example \
        > /etc/systemd/system/silent-failure-watchdog-alert.service
      cp scripts/95-hermes-watchdog-status /etc/update-motd.d/95-hermes-watchdog-status
      chmod +x /etc/update-motd.d/95-hermes-watchdog-status
      cp scripts/silent-failure-watchdog.timer.example /etc/systemd/system/silent-failure-watchdog.timer
      systemctl daemon-reload
      systemctl enable --now silent-failure-watchdog.timer
      echo "==> Watchdog installed and running (with its own failure alert, issue #85)."
      ;;
  esac
fi

echo ""
if systemctl is-enabled stuck-generation-watchdog.timer >/dev/null 2>&1; then
  echo "==> Stuck-generation watchdog already installed and enabled — skipping."
else
  read -r -p "Install the stuck-generation watchdog (recommended, issue #86)? [Y/n] " STUCK_WATCHDOG_REPLY
  case "${STUCK_WATCHDOG_REPLY}" in
    [nN]*) ;;
    *)
      echo "==> llama.cpp doesn't cancel a generation when hermes's own client"
      echo "    disconnects (see shared/hardware-sizing.md's 2026-09-10"
      echo "    incident) -- this alerts you via Telegram if llama-server ever"
      echo "    gets stuck running far longer than a reply should take, instead"
      echo "    of leaving you waiting with no idea anything is wrong. It does"
      echo "    NOT restart anything automatically -- you decide."
      REPO_PATH="$(cd .. && pwd)/linux-x86_64-vps"
      sed "s|REPLACE_WITH_REPO_PATH|${REPO_PATH}|g" scripts/stuck-generation-watchdog.service.example \
        > /etc/systemd/system/stuck-generation-watchdog.service
      cp scripts/stuck-generation-watchdog.timer.example /etc/systemd/system/stuck-generation-watchdog.timer
      systemctl daemon-reload
      systemctl enable --now stuck-generation-watchdog.timer
      echo "==> Watchdog installed and running."
      ;;
  esac
fi

./scripts/guided-demo.sh
