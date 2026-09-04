# Hermes Agent + llama.cpp — macOS Apple Silicon (ARM64)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

`llama-server` runs **natively** on the Mac to take advantage of **Metal** GPU
acceleration — Docker Desktop for Mac cannot expose the Metal GPU to a
container (the Linux containers it runs have no access to it), so running it
in Docker would fall back to CPU-only inference, defeating the purpose.
[llama-swap](https://github.com/mostlygeek/llama-swap) sits in front of it —
also native, also lightweight — so you can list more than one model and let
Hermes switch between them; see
[`../shared/managing-models.md`](../shared/managing-models.md). **Hermes**,
on the other hand, doesn't need a GPU (it's just the harness that calls the
model over HTTP): it runs in a `linux/arm64` Docker container and reaches
llama-swap via `host.docker.internal`.

```
┌────────────────────────── Mac (Apple Silicon) ───────────────────────────┐
│                                                                          │
│  scripts/run-llama-swap.sh                                              │
│        │                                                                │
│        ▼                                                                │
│  llama-swap (native)  ─────────►  http://host.docker.internal:8080/v1   │
│        │ spawns on demand                         ▲                     │
│        ▼                                          │                     │
│  llama-server (native, Metal)             ┌───────┴────────┐            │
│        │                                  │ Docker Desktop │            │
│        ▼                                  │  ┌───────────┐ │            │
│  .gguf model (./models)                   │  │  hermes   │ │            │
│                                            │  │ (arm64)   │ │            │
│                                            │  └─────┬─────┘ │            │
│                                            └────────┼───────┘            │
│                                                     ▼                    │
│                                        ./data (memory, skills)           │
└──────────────────────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
                                              Telegram (bot)
```

## Table of contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Starting](#starting)
- [Verification](#verification)
- [Running llama-swap in the background (optional)](#running-llama-swap-in-the-background-optional)
- [Managing models](#managing-models)
- [Common operations](#common-operations)
- [Native alternative (no Docker at all)](#native-alternative-no-docker-at-all)
- [Scripts reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)
- [Sources](#sources)

## Prerequisites

- An Apple Silicon Mac (M1/M2/M3/M4...).
- [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) — only used for the `hermes` container; skip it entirely with the [native alternative](#native-alternative-no-docker-at-all) below.
- **No compiler needed**: both `llama-server` and `llama-swap` are fetched as
  official prebuilt binaries (Metal included) by default — see
  [`../shared/prebuilt-binaries.md`](../shared/prebuilt-binaries.md). Xcode
  Command Line Tools + CMake are only required if you force a from-source
  `llama-server` build (`LLAMA_BUILD_FROM_SOURCE=1`).
- A Telegram bot — see [`../shared/telegram-setup.md`](../shared/telegram-setup.md).

CPU thread sizing on macOS isn't verified against real numbers the way
the VPS's is (Metal handles most of the work) — see
[`../shared/hardware-sizing.md`](../shared/hardware-sizing.md) and issue
[#14](https://github.com/ka8t/Hermes/issues/14).

> [`scripts/find-or-build-llama-server.sh`](scripts/find-or-build-llama-server.sh)
> picks, in order: an explicit `LLAMA_SERVER_BIN` override, an already-built
> `~/Documents/Code/llama.cpp/build/bin/llama-server`, a Homebrew install, the
> **official prebuilt binary** (default — see
> [`scripts/download-prebuilt-llama-server.sh`](scripts/download-prebuilt-llama-server.sh)),
> and only clones + builds into `./vendor` as a last resort. `run-llama-swap.sh`
> reads its result from `.env`'s `LLAMA_SERVER_BIN` rather than re-resolving it
> every time — run it once, paste the printed path into `.env`.

## Installation

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes/macos-arm64
cp .env.example .env
```

Edit `.env`: at minimum `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`
(details in [`../shared/telegram-setup.md`](../shared/telegram-setup.md)), and
`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (generate a real password
with `openssl rand -base64 24` — the dashboard refuses to start without one,
see [Verification](#verification)).

```bash
./scripts/download-prebuilt-llama-server.sh   # prints a path; paste it into .env as LLAMA_SERVER_BIN
./scripts/download-model.sh                   # downloads the default model into ./models
mkdir -p data
cp config/config.yaml.example data/config.yaml
cp config/models.yaml.example data/models.yaml
```

## Starting

**Terminal 1 — llama-swap + llama-server, natively:**

```bash
./scripts/run-llama-swap.sh
# ==> llama-swap : .../vendor/llama-swap/llama-swap
# ==> llama-server: .../vendor/llama.cpp-prebuilt/current/llama-server
# ==> Config      : data/models.yaml
# ==> Listening on: 127.0.0.1:8080  (web UI at /ui, models at /v1/models)
```

(llama-swap only starts `llama-server` once a request actually asks for a
model — the Metal load happens on the first real message, not here)

Keep this terminal open (or install it as a background service, see below).

**Terminal 2 — Hermes, in Docker:**

```bash
docker compose up -d
docker compose logs -f hermes
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

curl http://127.0.0.1:8080/health          # llama-swap
curl http://127.0.0.1:8080/v1/models       # should list "llama-3.1-8b-instruct"
docker compose exec hermes hermes doctor   # hermes
```

On Telegram, send the bot a message: "can you hear me?". A reply confirms
the whole chain works: Telegram → hermes container →
`host.docker.internal:8080` → llama-swap → `llama-server` (Metal) → model →
back. The first message will be slower than the rest — that's llama-swap
cold-starting `llama-server` and loading the model into Metal.

## Running llama-swap in the background (optional)

To avoid keeping a terminal open at all times, a `launchd` service template
is provided:

```bash
cp scripts/com.hermes.llama-swap.plist.example \
   ~/Library/LaunchAgents/com.hermes.llama-swap.plist
# edit the 3 occurrences of REPLACE_WITH_REPO_PATH in that file
launchctl load ~/Library/LaunchAgents/com.hermes.llama-swap.plist
```

Logs: `tail -f macos-arm64/llama-swap.log`. To stop it:
`launchctl unload ~/Library/LaunchAgents/com.hermes.llama-swap.plist`.

## Managing models

Edit `data/models.yaml` to add, change, or remove a model — both llama-swap
and Hermes pick it up without a restart. See
[`../shared/managing-models.md`](../shared/managing-models.md).

## Common operations

```bash
docker compose restart hermes
docker compose exec hermes hermes doctor --fix
docker compose down                        # stops hermes (./data and ./models persist)

# back up Hermes's memory/skills/sessions before anything risky
docker compose exec hermes hermes backup -o /opt/data/backup-$(date +%Y%m%d).tar.gz
docker compose cp hermes:/opt/data/backup-$(date +%Y%m%d).tar.gz .
```

### Iterating on `docker/Dockerfile`'s additions without a manual rebuild

If you're editing `../skills/agent-creation`, `../skills/reliability`, or
`../docker/Dockerfile` itself (the web_search schema patch, the approvals
default), run `docker compose watch` instead of `docker compose up -d` — it
picks up a skill edit by syncing it straight into the container and
restarting the Hermes process (no rebuild: the base image already
re-syncs skills into `/opt/data/skills` on every start), and rebuilds the
image automatically if the Dockerfile itself changes. See
[`docker-compose.yml`](docker-compose.yml)'s `develop.watch` block.

## Native alternative (no Docker at all)

Everything above already runs `llama-server`/llama-swap natively — the only
Docker dependency on this platform is the `hermes` container itself. If you'd
rather not use Docker Desktop at all, install Hermes natively too, via the
same official installer this project already relies on:

```bash
./scripts/install-hermes-native.sh    # curl | bash the official installer, idempotent
./scripts/setup-hermes-native.sh      # seeds ~/.hermes with this repo's config, approvals default, and skills
```

`setup-hermes-native.sh` never overwrites an existing `~/.hermes/config.yaml`
or `.env` — same "seed once" rule Hermes's own Docker image follows — so
re-running it later is safe. It writes a `config.yaml` pointing at
`http://127.0.0.1:8080/v1` (plain localhost — no `host.docker.internal`
workaround needed once Hermes itself isn't containerized), sets
`approvals.mode: manual` (see
[`../shared/enterprise-safety.md`](../shared/enterprise-safety.md)), and
copies this repo's [`skills/agent-creation`](../skills/agent-creation/) into
`~/.hermes/skills/ka8t-hermes/`.

Then, same two terminals as before, just without `docker compose`:

```bash
# terminal 1 — the model (identical to the Docker path)
./scripts/run-llama-swap.sh

# terminal 2 — Hermes, natively, as a persistent launchd service
hermes gateway install
hermes gateway start
hermes gateway setup     # once, to wire up Telegram
```

`hermes gateway install` sets up its own `launchd` service
(`ai.hermes.gateway-default`) — no custom service file needed, unlike
llama-swap's optional one (see
[`scripts/com.hermes.llama-swap.plist.example`](scripts/com.hermes.llama-swap.plist.example)).
Verification, troubleshooting, and everything else on this page apply the
same way — the only difference is `hermes doctor` / `hermes gateway status`
run directly instead of through `docker compose exec hermes`.

## Scripts reference

Every script under `scripts/` (except `install-hermes-native.sh`) starts
with `cd "$(dirname "${BASH_SOURCE[0]}")/.."`, so it relocates itself to
this directory (`macos-arm64/`) regardless of your current working
directory — run any of them as `./scripts/<name>.sh` from here, or by
relative/absolute path from anywhere else (a `launchd` job's `ProgramArguments`
included). `install-hermes-native.sh` has no directory dependency at all —
it installs to `$HOME` and can run from literally anywhere.

**`scripts/find-or-build-llama-server.sh`** — no parameters (optional env
vars: `LLAMA_SERVER_BIN` to force a specific binary, `LLAMA_BUILD_FROM_SOURCE=1`
to skip straight to a from-source build). Prints one binary path on stdout,
resolved in order: an explicit `LLAMA_SERVER_BIN` override → an existing
`~/Documents/Code/llama.cpp/build/bin/llama-server` → a Homebrew install →
the official prebuilt binary (calls `download-prebuilt-llama-server.sh`
itself) → clone + build from source into `./vendor/llama.cpp` as a last
resort (requires Xcode Command Line Tools + CMake). You normally don't call
this directly — it's what `.env`'s `LLAMA_SERVER_BIN` should end up pointing
at, resolved once.

**`scripts/download-prebuilt-llama-server.sh`** — no parameters. Downloads
the latest official `bin-macos-arm64.tar.gz` release asset from
`ggml-org/llama.cpp` (Metal included) into
`./vendor/llama.cpp-prebuilt/current/` and prints the resulting
`llama-server` binary's path on stdout. Skips the download if the archive is
already present.

**`scripts/download-llama-swap.sh`** — no parameters. Downloads the latest
stable `darwin_arm64` release of `llama-swap` into `./vendor/llama-swap/`
and prints the binary's path on stdout. Called automatically by
`run-llama-swap.sh` — you don't need to run it yourself unless you want the
binary path in isolation.

**`scripts/download-model.sh`** — no parameters (reads `MODEL_FILE` /
`MODEL_REPO` from `.env`, falling back to
`Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` /
`bartowski/Meta-Llama-3.1-8B-Instruct-GGUF`). Downloads into `./models/` if
not already present; a no-op otherwise.

**`scripts/run-llama-swap.sh`** — no parameters (reads `LLAMA_PORT` and
`LLAMA_SERVER_BIN` from `.env`). Requires `data/models.yaml` (copy from
`config/models.yaml.example`) and `LLAMA_SERVER_BIN` set to an executable.
Keeps running in the foreground, bound to `127.0.0.1` — install as a
`launchd` service with `scripts/com.hermes.llama-swap.plist.example` to run
it unattended.

**`scripts/verify-inference.sh`** — no parameters (optional env var:
`LLAMA_URL`, default `http://127.0.0.1:8080`). The mandatory
post-provisioning check (issue #27): measures *real* prompt-processing
and generation throughput against this exact running deployment,
instead of only detecting hardware specs. Requires llama-swap up; Hermes
running (Docker or native) is optional — if it's up, also estimates a
real first-reply latency from `hermes prompt-size`'s actual prompt
budget for this deployment (PASS under 5 min, WARN 5-20 min, FAIL
above); if Hermes isn't up, still prints valid throughput numbers with
a plain warning that the latency estimate was skipped. See
[`shared/hardware-sizing.md`](../shared/hardware-sizing.md) for the
thresholds' calibration.

**`scripts/install-hermes-native.sh`** — native-Hermes path only. No
parameters. Idempotent (does nothing if `hermes` is already on `PATH`);
otherwise runs the official installer.

**`scripts/setup-hermes-native.sh`** — native-Hermes path only. No
parameters (optional env var: `HERMES_HOME`, default `~/.hermes`). Requires
`hermes` on `PATH` (run `install-hermes-native.sh` first). Never overwrites
an existing `config.yaml` or `.env` under `HERMES_HOME` — seeds them only if
missing — and always re-syncs `skills/ka8t-hermes/agent-creation/` from this
repo.

**Not available on macOS**: `build-agent-template.sh` and
`provision-user.sh` (multi-user profile isolation) currently only exist
under [`linux-x86_64-vps/scripts/`](../linux-x86_64-vps/scripts/) — see
[`../shared/multi-user-agents.md`](../shared/multi-user-agents.md).

## Troubleshooting

| Symptom | What to check |
|---|---|
| `Connection refused` from the hermes container | llama-swap isn't running — check `./scripts/run-llama-swap.sh` in terminal 1 |
| `LLAMA_SERVER_BIN is not set to an executable` | Run `./scripts/download-prebuilt-llama-server.sh` and paste its printed path into `.env` |
| Very slow replies / all-CPU | The `llama-server` startup logs (visible in the llama-swap terminal/log once a model is requested) should mention `ggml_metal_device_init` — if it's missing, check which binary `.env`'s `LLAMA_SERVER_BIN` actually points to |
| Tool calls come back as JSON text instead of running | The `--jinja` flag is missing from that model's `cmd` in `data/models.yaml` (present in `models.yaml.example`) |
| Hermes says a model isn't found | The `model.default` in `data/config.yaml` doesn't match a model ID in `data/models.yaml` exactly — see [`../shared/managing-models.md`](../shared/managing-models.md) |
| `docker: no matching manifest for linux/arm64` | Stale cached `hermes-agent` image — `docker compose pull` |
| Dashboard won't start / login loop | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` missing or empty in `.env` |
| Gateway crashes on startup: `FATAL: a live process holds a deleted state.db-wal or state.db-shm inode...` | Docker Desktop's virtiofs bind mount and SQLite's WAL mode don't reliably mix — see [`../shared/telegram-setup.md`](../shared/telegram-setup.md)'s troubleshooting table for the fix (`database.journal_mode: delete`, already the default in `config/config.yaml.example`) |

## Sources

- Prebuilt binaries (what's inside, how they're fetched): [`../shared/prebuilt-binaries.md`](../shared/prebuilt-binaries.md)
- Managing multiple models: [`../shared/managing-models.md`](../shared/managing-models.md)
- llama.cpp Metal support: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- llama-swap: [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
- Hermes image and volumes (multi-arch amd64/arm64 confirmed on Docker Hub): [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- `custom` provider / `config.yaml`: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- Hermes dashboard auth (fail-closed on non-loopback binds): [hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard)
- `host.docker.internal` on Docker Desktop for Mac: [official Docker documentation](https://docs.docker.com/desktop/networking/)
- Native install / `HERMES_HOME` / `hermes gateway install`: [hermes-agent.nousresearch.com/docs/getting-started/installation](https://hermes-agent.nousresearch.com/docs/getting-started/installation) and [reference/cli-commands](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)
