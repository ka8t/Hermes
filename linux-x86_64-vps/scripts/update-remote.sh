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
# Does NOT touch llama-swap or the model -- those rarely change and a
# restart there interrupts any in-flight generation (see
# shared/hardware-sizing.md's 2026-09-10 incident on why that's not
# free). Re-run this script with --restart-llama-swap if you specifically
# need to pick up a config/models.yaml change too.
set -euo pipefail

SSH_HOST="${1:?Usage: $0 <ssh-host-alias-or-user@host> [--restart-llama-swap]}"
RESTART_LLAMA_SWAP=0
if [ "${2:-}" = "--restart-llama-swap" ]; then
  RESTART_LLAMA_SWAP=1
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

if [ "${RESTART_LLAMA_SWAP}" -eq 1 ]; then
  echo "==> --restart-llama-swap passed: restarting llama-swap too"
  ssh_run "cd ~/${REMOTE_REPO_DIR}/linux-x86_64-vps && docker compose restart llama-swap"
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

echo "==> Update complete. This did not restart llama-swap or reload the model"
echo "    (pass --restart-llama-swap if config/models.yaml also changed) --"
echo "    for a deeper check of real inference throughput, run"
echo "    ./scripts/verify-inference.sh on the VPS itself."
