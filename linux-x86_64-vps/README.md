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
- [Common operations](#common-operations)
- [Native alternative (no Docker at all)](#native-alternative-no-docker-at-all)
- [Managing models](#managing-models)
- [Scripts reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)
- [Sources](#sources)

## Prerequisites

- An Ubuntu 22.04+ VPS (x86-64), at least 8 GB of RAM for a 7B model in `Q4_K_M`.
- Root/sudo access over SSH.
- Docker Engine + Compose plugin (installed by `provision.sh` if missing) — skip it entirely with the [native alternative](#native-alternative-no-docker-at-all) below.
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
   without one, see [Verification](#verification)).
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
alone facing the open internet.

## Common operations

```bash
docker compose restart hermes        # restarts just the agent
docker compose exec hermes hermes doctor --fix
docker compose logs --tail 100 llama-swap
docker compose down                  # stop (data persists in ./data and ./models)
docker compose pull && docker compose up -d   # update images

# back up Hermes's memory/skills/sessions before anything risky
docker compose exec hermes hermes backup -o /opt/data/backup-$(date +%Y%m%d).tar.gz
docker compose cp hermes:/opt/data/backup-$(date +%Y%m%d).tar.gz .
```

## Native alternative (no Docker at all)

Everything above runs in Docker Compose. If you'd rather not use Docker on
this VPS at all, both `llama-swap`/`llama-server` and Hermes can run
natively instead, via the same official binaries and installer this repo
already relies on elsewhere:

```bash
# llama-swap + llama-server, natively (mirrors macos-arm64/'s native path)
[ -f .env ] || cp .env.example .env           # if you never ran provision.sh, .env doesn't exist yet
./scripts/download-prebuilt-llama-server.sh   # prints a path; paste it into .env as LLAMA_SERVER_BIN
./scripts/download-llama-swap.sh              # fetches llama-swap itself
mkdir -p models data
# download a model into ./models/ — see ../shared/model-notes.md
cp config/models.yaml.example.native data/models.yaml
./scripts/run-llama-swap-native.sh            # also auto-sizes LLAMA_THREADS to your real core count
                                               # (issue #12) if .env was just created; keep running, or
                                               # install as a systemd service:
#   sudo cp scripts/llama-swap.service.example /etc/systemd/system/llama-swap.service
#   # edit the REPLACE_WITH_REPO_PATH occurrences, then:
#   sudo systemctl daemon-reload && sudo systemctl enable --now llama-swap

# Hermes, natively
./scripts/install-hermes-native.sh    # curl | bash the official installer, idempotent
./scripts/setup-hermes-native.sh      # seeds ~/.hermes with this repo's config, approvals default, and skills
hermes gateway install                # sets up its own systemd user service
hermes gateway start
hermes gateway setup                  # once, to wire up Telegram
```

`setup-hermes-native.sh` never overwrites an existing `~/.hermes/config.yaml`
or `.env` — same "seed once" rule Hermes's own Docker image follows. The
seeded `config.yaml` points at `http://127.0.0.1:8080/v1` — plain localhost,
since both processes now run directly on this VPS with no Docker networking
involved. Verification, troubleshooting, and everything else on this page
apply the same way — run `hermes doctor` / `hermes gateway status` directly
instead of through `docker compose exec hermes`.

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
systemd unit's `ExecStart`, a CI step). The one exception is
`install-hermes-native.sh`, which has no directory dependency at all — it
installs to `$HOME` and can run from literally anywhere.

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

**`scripts/install-hermes-native.sh`** — native path only. No parameters.
Idempotent (does nothing if `hermes` is already on `PATH`); otherwise runs
the official installer.

**`scripts/setup-hermes-native.sh`** — native path only. No parameters
(optional env var: `HERMES_HOME`, default `~/.hermes`). Requires `hermes` on
`PATH` (run `install-hermes-native.sh` first). Never overwrites an existing
`config.yaml` or `.env` under `HERMES_HOME` — seeds them only if missing —
and always re-syncs `skills/ka8t-hermes/agent-creation/` from this repo.

**`scripts/download-prebuilt-llama-server.sh`** — native path only. No
parameters. Downloads the latest official `bin-ubuntu-x64.tar.gz` release
asset from `ggml-org/llama.cpp` into `./vendor/llama.cpp-prebuilt/current/`
and prints the resulting `llama-server` binary's path on stdout — paste that
path into `.env` as `LLAMA_SERVER_BIN`. Skips the download if the archive is
already present.

**`scripts/download-llama-swap.sh`** — native path only. No parameters.
Downloads the latest stable `linux_amd64` release of `llama-swap` into
`./vendor/llama-swap/` and prints the binary's path on stdout. Called
automatically by `run-llama-swap-native.sh` — you don't need to run it
yourself unless you want the binary path in isolation.

**`scripts/run-llama-swap-native.sh`** — native path only. No parameters
(reads `LLAMA_PORT`, `LLAMA_SERVER_BIN`, `MODEL_FILE`, `LLAMA_CTX_SIZE`,
`LLAMA_THREADS` from `.env`). Requires `data/models.yaml` (copy from
`config/models.yaml.example.native`) and `LLAMA_SERVER_BIN` set to an
executable. Keeps running in the foreground — install as a systemd service
with `scripts/llama-swap.service.example` to run it unattended.

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
