#!/usr/bin/env bash
# Update a remote VPS deployment from your local machine (issue #87) --
# pulls this repo's latest commits and the latest ghcr.io/ka8t/hermes
# image (built automatically by .github/workflows/publish-image.yml on
# every docker/**/skills/** push to main), recreates the hermes
# container, and confirms it comes back up before finishing.
#
# Every other script in this directory runs ON the VPS itself
# (provision.sh is curl'd or cloned directly there) -- this one is the
# exception, meant to run from your own machine.
#
# SSH connection: deliberately NOT this repo's concern (found live,
# 2026-09-10, no reason to duplicate what ~/.ssh/config already does
# well) -- this script takes a plain SSH target (a Host alias from your
# own ~/.ssh/config, or a bare user@host) as its first argument. Set one
# up once, e.g.:
#   Host my-hermes-vps
#     HostName 203.0.113.10
#     User debian
#     IdentityFile ~/.ssh/id_ed25519
# then: ./scripts/update-remote.sh my-hermes-vps
#
# Does NOT touch llama-server or the model by default -- a restart there
# interrupts any in-flight generation (see shared/hardware-sizing.md's
# 2026-09-10 incident on why that's not free). Pass
# --update-llama-server to re-download the latest official llama-server
# binary (see ./download-prebuilt-llama-server.sh) and recreate that
# container too -- do this periodically even without a repo change,
# since llama-server has its own upstream release cadence this repo
# doesn't otherwise track (issue #101, 2026-09-15: a stale bundled
# llama-swap:cpu image ran unnoticed for two weeks through a real
# incident before this repo dropped llama-swap and started tracking the
# binary directly).
set -euo pipefail

SSH_HOST="${1:?Usage: $0 <ssh-host-alias-or-user@host> [--update-llama-server]}"
UPDATE_LLAMA_SERVER=0
if [ "${2:-}" = "--update-llama-server" ]; then
  UPDATE_LLAMA_SERVER=1
fi

REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-hermes}"

ssh_run() {
  ssh -o ConnectTimeout=10 "${SSH_HOST}" "$@"
}

echo "==> Checking ${SSH_HOST} is reachable..."
if ! ssh_run true; then
  echo "!! Could not SSH to '${SSH_HOST}' -- check the host alias/address and your ~/.ssh/config." >&2
  exit 1
fi

echo "==> Pulling latest commits on ${SSH_HOST}:~/${REMOTE_REPO_DIR}"
ssh_run "cd ~/${REMOTE_REPO_DIR} && git pull --ff-only"

echo "==> Pulling the latest ghcr.io/ka8t/hermes image"
ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose pull hermes"

echo "==> Recreating the hermes container"
ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose up -d hermes"

if [ "${UPDATE_LLAMA_SERVER}" -eq 1 ]; then
  echo "==> --update-llama-server passed: downloading the latest llama-server binary"
  ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && ./scripts/download-prebuilt-llama-server.sh"
  echo "==> Recreating llama-server to pick it up"
  ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose up -d --build llama-server"
fi

echo "==> Waiting for the hermes container to report Up..."
UP=0
for _ in $(seq 1 30); do
  STATUS="$(ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose ps hermes --format '{{.Status}}'" 2>/dev/null || true)"
  if echo "${STATUS}" | grep -qi '^up'; then
    echo "==> hermes: ${STATUS}"
    UP=1
    break
  fi
  sleep 2
done

if [ "${UP}" -eq 0 ]; then
  echo "!! hermes did not report Up within 60s -- check: ssh ${SSH_HOST} 'cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose logs hermes --tail 50'" >&2
  exit 1
fi

echo "==> Update complete. This did not touch llama-server or the model"
echo "    (pass --update-llama-server to fetch the latest binary too) --"
echo "    for a deeper check of real inference throughput, run"
echo "    ./scripts/verify-inference.sh on the VPS itself."
