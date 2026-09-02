# Hermes Agent + llama.cpp — Linux x86-64 VPS (Docker)

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

## Prerequisites

- An Ubuntu 22.04+ VPS (x86-64), at least 8 GB of RAM for a 7B model in `Q4_K_M`.
- Root/sudo access over SSH.
- A Telegram bot — see [`../shared/telegram-setup.md`](../shared/telegram-setup.md).

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
# llama-swap health and model list
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/models       # should list "qwen2.5-coder-7b"

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

## Managing models

Edit `data/models.yaml` to add, change, or remove a model — the container is
started with `-watch-config`, so both llama-swap and Hermes pick up the
change without a restart. See
[`../shared/managing-models.md`](../shared/managing-models.md).

## Troubleshooting

| Symptom | What to check |
|---|---|
| `hermes` stays `starting` | `llama-swap` hasn't finished loading the model yet — check `docker compose logs llama-swap` |
| Tool calls come back as raw JSON text instead of running | The `--jinja` flag is missing from that model's `cmd` in `data/models.yaml` (present in `models.yaml.example`) |
| Hermes says a model isn't found | `model.default` in `data/config.yaml` doesn't match a model ID in `data/models.yaml` exactly — see [`../shared/managing-models.md`](../shared/managing-models.md) |
| Slow / truncated responses | `LLAMA_CTX_SIZE` or `LLAMA_THREADS` poorly sized for the rented VPS — adjust in `.env` |
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
- Telegram variables: [hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
