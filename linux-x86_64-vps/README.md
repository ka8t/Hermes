# Hermes Agent + llama.cpp — Linux x86-64 VPS (Docker)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

A fully Docker Compose stack, designed for a small Ubuntu VPS (e.g. a
Hostinger KVM2, 2 vCPU / 8 GB RAM): a `llama-swap` container serves one or
more GGUF models locally (loading/unloading them on demand — see
[`../shared/managing-models.md`](../shared/managing-models.md) to add more
than the default one), a `hermes` container runs the agent and connects to
it internally — no external API key, nothing leaves the server except
Telegram messages.

```
┌──────────────────────────── VPS (docker compose) ───────────────────────────┐
│                                                                              │
│   ┌───────────────────┐    http://llama-swap:8080/v1    ┌───────────────┐   │
│   │    llama-swap      │ ◄──────────────────────────────│    hermes     │   │
│   │ ghcr.io/mostlygeek/│        (internal network)       │ nousresearch/ │   │
│   │  llama-swap:cpu    │                                 │ hermes-agent  │   │
│   └─────────┬──────────┘                                 └───────┬───────┘   │
│             │ spawns /app/llama-server on demand                 │           │
│             ▼                                                    ▼           │
│        .gguf model(s)  ◄── ./models (read-only)          ./data (memory,    │
│        ./data/models.yaml                                 skills, config)   │
└──────────────────────────────────────────────────────────────────────────────┘
                                                                    │
                                                                    ▼
                                                             Telegram (bot)
```

## Table of contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Starting](#starting)
- [Verification](#verification)
- [Silent-failure watchdog (optional)](#silent-failure-watchdog-optional)
- [Common operations](#common-operations)
- [Managing models](#managing-models)
- [Scripts reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)
- [Sources](#sources)

## Prerequisites

- An Ubuntu 22.04+ VPS (x86-64), at least 8 GB of RAM for a 7B model in `Q4_K_M`.
- Root/sudo access over SSH.
- Docker Engine + Compose plugin (installed by `provision.sh` if missing) — this platform is Docker-only, see [`../docs/adr/0001-vps-docker-only.md`](../docs/adr/0001-vps-docker-only.md) for why. Want no Docker at all? Use [`../macos-arm64/`](../macos-arm64/) instead, which still offers a native path.
- A Telegram bot — see [`../shared/telegram-setup.md`](../shared/telegram-setup.md).
- No GPU required — this path is CPU-only by default. If your VPS does have
  an NVIDIA GPU, see [`../shared/gpu-setup.md`](../shared/gpu-setup.md)
  (implemented, not live-verified — see that page's status note).

## Installation

```bash
ssh root@<vps-ip>
git clone https://github.com/ka8t/Hermes.git
cd Hermes/linux-x86_64-vps
./provision.sh
```

`provision.sh` installs Docker + the Compose plugin if missing, creates the
persistent folders (`data/`, `models/`), copies `.env.example` → `.env`,
`config/config.yaml.example` → `data/config.yaml` and
`config/models.yaml.example` → `data/models.yaml`, then downloads the
default model (see [`../shared/model-notes.md`](../shared/model-notes.md) to
change it, or [`../shared/managing-models.md`](../shared/managing-models.md)
to add more).

## Configuration

1. **Edit `.env`** — at minimum `TELEGRAM_BOT_TOKEN` and
   `TELEGRAM_ALLOWED_USERS` (details in
   [`../shared/telegram-setup.md`](../shared/telegram-setup.md)), and
   `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (generate a real
   password with `openssl rand -base64 24` — the dashboard refuses to start
   without one, see [Verification](#verification)). This `.env` — right here
   at the project root — is the only one: hermes-agent's own setup wizards
   (`hermes gateway setup`, etc.) write back into this exact file too, not a
   separate copy under `data/`. See
   [`../shared/single-env-file.md`](../shared/single-env-file.md) for how
   (a symlink in Docker mode, not a direct bind-mount — different from
   macOS, see that doc for why).
2. **`data/config.yaml`** is already prepared (copied from
   `config/config.yaml.example`): it points Hermes at
   `http://llama-swap:8080/v1`, the neighboring service's name in
   `docker-compose.yml` — Docker Compose resolves that name automatically, no
   IP address to manage.
3. **`data/models.yaml`** is also already prepared (copied from
   `config/models.yaml.example`) with the one default model. Edit it any
   time to add, change, or remove models — see
   [`../shared/managing-models.md`](../shared/managing-models.md).

## Starting

```bash
docker compose up -d
docker compose logs -f llama-swap
# wait for it to report healthy (docker compose ps)
```

Then, **once**, wire up Telegram:

```bash
docker compose exec hermes hermes gateway setup
```

## Verification

```bash
# Mandatory: real inference throughput, not just "is it up" — hardware
# specs alone don't predict real speed (see ../shared/hardware-sizing.md).
./scripts/verify-inference.sh

# llama-swap health and model list
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/models       # should list "llama-3.1-8b-instruct"

# agent status
docker compose exec hermes hermes doctor

# agent logs
docker compose logs -f hermes
```

Then, on Telegram, send the bot a message: "can you hear me?". A reply
confirms the whole chain works (Telegram → hermes → llama-swap →
`llama-server` → model → back). The first message will be slower than the
rest — that's llama-swap cold-starting `llama-server` and loading the model.

The web dashboard is available at `http://<vps-ip>:9119` if
`HERMES_DASHBOARD=1` (the default in `.env.example`) — it requires the
`HERMES_DASHBOARD_BASIC_AUTH_*` credentials set in step 1 above (the
dashboard refuses to start without them once reachable from outside
`127.0.0.1`, which it is via the Docker port mapping); still put it behind a
firewall or an SSH tunnel as a second layer, don't rely on the password
alone facing the open internet. See
[`../shared/web-dashboard.md`](../shared/web-dashboard.md) for what it
actually offers (chat, sessions, cron, logs, config, and more) and why to
reconfigure rather than keep an unknown existing password on a re-run.

## Silent-failure watchdog (optional)

A known upstream gap (hermes-agent's tool-calling loop, not this repo's
code — see [issue #56](https://github.com/ka8t/Hermes/issues/56)) can end a
Telegram session with no reply at all after a tool error. A systemd timer
runs `scripts/silent-failure-watchdog.sh` every 5 minutes to detect that
and send the affected user a fallback message directly, bypassing
hermes-agent for that one message — this is the actually-unattended
deployment, so a real user could otherwise be left with silence and no one
noticing:

```bash
sudo cp scripts/silent-failure-watchdog.service.example /etc/systemd/system/silent-failure-watchdog.service
sudo cp scripts/silent-failure-watchdog-alert.service.example /etc/systemd/system/silent-failure-watchdog-alert.service
sudo cp scripts/silent-failure-watchdog.timer.example /etc/systemd/system/silent-failure-watchdog.timer
sudo cp scripts/95-hermes-watchdog-status /etc/update-motd.d/95-hermes-watchdog-status
sudo chmod +x /etc/update-motd.d/95-hermes-watchdog-status
# edit the REPLACE_WITH_REPO_PATH occurrences in BOTH .service files
sudo systemctl daemon-reload
sudo systemctl enable --now silent-failure-watchdog.timer
```

Logs: `journalctl -u silent-failure-watchdog.service`. To stop it:
`sudo systemctl disable --now silent-failure-watchdog.timer`.

This watchdog is itself a single point of failure for the whole safety
net above — [issue #85](https://github.com/ka8t/Hermes/issues/85), found
live 2026-09-10: a blank `TELEGRAM_BOT_TOKEN` made it fail silently for
~35 minutes, visible only in the journal. `silent-failure-watchdog.sh` now
tracks every run's outcome in `~/.hermes/silent-failure-watchdog.state.json`;
`OnFailure=` on the main service triggers an immediate `wall` broadcast to
anyone logged in, and `95-hermes-watchdog-status` (installed above) shows a
persistent SSH login-banner warning for as long as the failure lasts.

### Stuck-generation watchdog (optional, issue #86)

llama.cpp/llama-swap don't cancel a generation when hermes's own client
disconnects — a stuck request can occupy `llama-server`'s single slot far
longer than `config/models.yaml`'s `--predict` cap should allow, with every
retry queuing up behind it (see
[`../shared/hardware-sizing.md`](../shared/hardware-sizing.md)'s 2026-09-10
incident). `scripts/stuck-generation-watchdog.sh`, run every 5 minutes,
detects this (no completed request logged in far longer than a completion
should ever take) and sends a Telegram alert to `TELEGRAM_HOME_CHANNEL` —
deliberately does **not** restart anything itself; a human decides:

```bash
sudo cp scripts/stuck-generation-watchdog.service.example /etc/systemd/system/stuck-generation-watchdog.service
sudo cp scripts/stuck-generation-watchdog.timer.example /etc/systemd/system/stuck-generation-watchdog.timer
# edit the REPLACE_WITH_REPO_PATH occurrence in the .service file
sudo systemctl daemon-reload
sudo systemctl enable --now stuck-generation-watchdog.timer
```

If it fires: `docker compose exec llama-swap ps aux` to confirm, then
`docker compose restart llama-swap` to clear it.

## Common operations

```bash
docker compose restart hermes        # restarts just the agent
docker compose exec hermes hermes doctor --fix
docker compose logs --tail 100 llama-swap
docker compose down                  # stop (data persists in ./data and ./models)
docker compose pull && docker compose up -d   # update images (run ON the VPS)

# back up Hermes's memory/skills/sessions before anything risky
docker compose exec hermes hermes backup -o /opt/data/backup-$(date +%Y%m%d).tar.gz
docker compose cp hermes:/opt/data/backup-$(date +%Y%m%d).tar.gz .

# from YOUR OWN machine instead (issue #87): pull + recreate over SSH
./scripts/update-remote.sh <your-ssh-host-alias>
```

## Managing models

Edit `data/models.yaml` to add, change, or remove a model — the container is
started with `-watch-config`, so both llama-swap and Hermes pick up the
change without a restart. See
[`../shared/managing-models.md`](../shared/managing-models.md).

## Scripts reference

Every script under `scripts/` starts with `cd "$(dirname "${BASH_SOURCE[0]}")/.."`,
so it relocates itself to this directory (`linux-x86_64-vps/`) regardless of
your current working directory — run any of them as `./scripts/<name>.sh`
from here, or by relative/absolute path from anywhere else (a cron job, a
systemd unit's `ExecStart`, a CI step).

**`provision.sh`** (repo root of this directory, not under `scripts/`) — run
**once, as root**, on a fresh VPS. No parameters. Installs Docker Engine +
the Compose plugin if missing, creates `data/`/`models/`, seeds
`.env`/`data/config.yaml`/`data/models.yaml` from their `.example` files
(only if each doesn't already exist), then downloads the default model —
reading `MODEL_FILE`/`MODEL_REPO` from `.env` if set, otherwise falling back
to `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` /
`bartowski/Meta-Llama-3.1-8B-Instruct-GGUF`. Safe to re-run — every step is
guarded by an existence check, so it never overwrites something you've
already configured.

**`scripts/configure-telegram.sh`** — added 2026-09-08 (issue #10). No
parameters (requires `GATEWAY_SETUP_CMD` in the environment, set by
`provision.sh`). If `TELEGRAM_BOT_TOKEN` in `.env` is already a real value
(not `.env.example`'s placeholder), first calls Telegram's `getMe` to check
it still resolves to a real bot (catches a bot deleted via BotFather's
`/deletebot`, which leaves a dead token sitting in `.env` — never trusted
blindly): if it works, shows it masked (`...last 4 chars`) plus the
current `TELEGRAM_ALLOWED_USERS` and asks "Reconfigure it anyway? [y/N]"
— declining leaves `.env` untouched and skips the wizard entirely; if
Telegram rejects the token outright, skips straight to reconfiguring, no
prompt (a dead token is never worth keeping); if `api.telegram.org` can't
be reached at all (network issue), asks the same y/N but says plainly the
check was unverified. Otherwise (never configured, or you say yes),
prints the BotFather instructions and runs `hermes gateway setup`.

**`scripts/build-agent-template.sh`** — Docker path only. No parameters
(optional env var: `AGENT_TEMPLATE_PROFILE`, default `agent-template`, to
name the template profile differently). Requires the `hermes` container
already running (`docker compose up -d`). Creates the profile inside the
container the first time, then **always** overwrites its `config.yaml` and
`skills/ka8t-hermes/agent-creation/` from this repo's own
`config/config.yaml.example` and `../skills/agent-creation/` — re-run it any
time those files change, to keep the template in sync. See
[`../shared/multi-user-agents.md`](../shared/multi-user-agents.md).

**`scripts/provision-user.sh <platform> <chat_id> <profile-slug>`** — Docker
path only. Three required positional arguments, e.g.
`./scripts/provision-user.sh telegram 987654321 alice` (in a Telegram DM,
`chat_id` equals the sender's numeric `user_id` — see
[`../shared/telegram-setup.md`](../shared/telegram-setup.md)). Requires the
template profile from `build-agent-template.sh` to exist already. Clones a
new profile for that user, adds a `gateway.profile_routes` entry routing
their `platform`+`chat_id` to it, and restarts the gateway — only when
something actually changed (idempotent: a second call with the same
arguments is a no-op; a `chat_id` already routed to a *different* profile is
refused, not overwritten, and no profile is created in that case). Does
**not** decide who is allowed to talk to the bot — that's
`TELEGRAM_ALLOWED_USERS` / `hermes pairing approve`, a human decision made
before this script ever runs.

**`scripts/verify-inference.sh`** — no parameters (optional env var:
`LLAMA_URL`, default `http://127.0.0.1:8080`). The mandatory
post-provisioning check (issue #27): measures *real* prompt-processing
and generation throughput against this exact running deployment (CPU or
GPU, whatever's actually configured), instead of only detecting
hardware specs. Requires `docker compose up -d`'s llama-swap to be
healthy; if the `hermes` container is also up, additionally estimates a
real first-reply latency from `hermes prompt-size`'s actual prompt
budget for this deployment (PASS under 5 min, WARN 5-20 min, FAIL
above); otherwise still prints valid throughput numbers with a plain
warning that the latency estimate was skipped. Provisioning is not
considered done until this passes — see
[`../shared/hardware-sizing.md`](../shared/hardware-sizing.md) for the
thresholds' calibration.

**`scripts/silent-failure-watchdog.sh`** — no required parameters (optional
env var: `HERMES_MODE`, `docker` (default) or `native`, matching
`eval/lib-hermes-env.sh`'s convention). Local stopgap for
[issue #56](https://github.com/ka8t/Hermes/issues/56): polls `state.db`
for Telegram sessions whose most recent message is from the user with no
non-empty assistant reply after it, once more time has passed than this
deployment's own `agent.local_stream_stale_timeout` (config.yaml) allows
for legitimate slow inference (times 3, to cover hermes-agent's own
full retry budget — see [issue #85](https://github.com/ka8t/Hermes/issues/85))
— a real upstream hermes-agent gap this repo can't fix directly — and
sends the affected user a fixed fallback message straight via the
Telegram Bot API, bypassing hermes-agent for that one message. Tracks
already-notified message IDs at
`~/.hermes/silent-failure-watchdog.notified-ids` so the same dangling
message is never notified twice, and every run's own outcome at
`~/.hermes/silent-failure-watchdog.state.json` (issue #85 — see "Silent-
failure watchdog" above for what reads this). Meant to run every few
minutes via `silent-failure-watchdog.timer.example`, not invoked manually
in normal use.

**`scripts/stuck-generation-watchdog.sh`** — no required parameters
(optional env vars: `STUCK_THRESHOLD_S`, default `1800`;
`LLAMA_SWAP_CONTAINER`, default `llama-swap`). See "Stuck-generation
watchdog" above for what it does and why it deliberately doesn't restart
anything.

**`scripts/update-remote.sh <ssh-host-alias> [--restart-llama-swap]`** —
run from **your own local machine**, not the VPS (the one script in this
directory that isn't) — see [issue #87](https://github.com/ka8t/Hermes/issues/87).
Takes an SSH target (a `Host` alias from your own `~/.ssh/config`, or a
bare `user@host`) as its first argument; this repo deliberately doesn't
store or manage SSH connection details itself, see the script's own header
comment. Pulls this repo's latest commits and the latest
`ghcr.io/ka8t/hermes` image on the VPS, recreates the `hermes` container,
and waits for it to report `Up`. Does **not** touch `llama-swap` or reload
the model by default (a restart there can interrupt an in-flight
generation — see `shared/hardware-sizing.md`'s 2026-09-10 incident) —
pass `--restart-llama-swap` if `config/models.yaml` also changed.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `hermes` stays `starting` | `llama-swap` hasn't finished loading the model yet — check `docker compose logs llama-swap` |
| Tool calls come back as raw JSON text instead of running | The `--jinja` flag is missing from that model's `cmd` in `data/models.yaml` (present in `models.yaml.example`) |
| Hermes says a model isn't found | `model.default` in `data/config.yaml` doesn't match a model ID in `data/models.yaml` exactly — see [`../shared/managing-models.md`](../shared/managing-models.md) |
| Slow / truncated responses | `LLAMA_CTX_SIZE` or `LLAMA_THREADS` poorly sized for the rented VPS — adjust in `.env`. `provision.sh` auto-detects vCPU count on first run and sets `LLAMA_THREADS` accordingly (total minus 1), but if `.env` predates that, or you resized the VPS after provisioning, check `nproc` yourself — see [`../shared/hardware-sizing.md`](../shared/hardware-sizing.md) for the full incident this fix came from and what to check before assuming a slow response is hardware-bound |
| The Telegram bot never replies | `TELEGRAM_ALLOWED_USERS` doesn't match your real user ID — revisit [`../shared/telegram-setup.md`](../shared/telegram-setup.md) |
| Dashboard won't start / login loop | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` missing or empty in `.env` |

## Sources

- Prebuilt binaries (what's inside, how they're fetched): [`../shared/prebuilt-binaries.md`](../shared/prebuilt-binaries.md)
- Managing multiple models: [`../shared/managing-models.md`](../shared/managing-models.md)
- llama-swap: [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
- llama.cpp flags: [ggml-org/llama.cpp — docs/docker.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- Hermes image and volumes: [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- `custom` provider / `config.yaml`: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- Hermes dashboard auth (fail-closed on non-loopback binds): [hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard)
- Native install / `HERMES_HOME` / `hermes gateway install`: [hermes-agent.nousresearch.com/docs/getting-started/installation](https://hermes-agent.nousresearch.com/docs/getting-started/installation) and [reference/cli-commands](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)
- Telegram variables: [hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
