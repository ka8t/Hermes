# Hermes Agent + llama.cpp — Linux x86-64 VPS (Docker)

A fully Docker Compose stack, designed for a small Ubuntu VPS (e.g. a
Hostinger KVM2, 2 vCPU / 8 GB RAM): a `llama-server` container serves a GGUF
model locally, a `hermes` container runs the agent and connects to it
internally — no external API key, nothing leaves the server except Telegram
messages.

```
┌─────────────────────────── VPS (docker compose) ───────────────────────────┐
│                                                                             │
│   ┌───────────────────┐   http://llama-server:8080/v1   ┌───────────────┐  │
│   │   llama-server     │ ◄────────────────────────────── │    hermes     │  │
│   │ ghcr.io/ggml-org/  │        (internal network)        │ nousresearch/ │  │
│   │  llama.cpp:server  │                                  │ hermes-agent  │  │
│   └─────────┬──────────┘                                  └───────┬───────┘  │
│             │ ./models (read-only)                                │          │
│             ▼                                                     ▼          │
│        .gguf model                                       ./data (memory,    │
│                                                            skills, config)   │
└─────────────────────────────────────────────────────────────────────────────┘
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
persistent folders (`data/`, `models/`), copies `.env.example` → `.env` and
`config/config.yaml.example` → `data/config.yaml`, then downloads the default
model (see [`../shared/model-notes.md`](../shared/model-notes.md) to change
it).

## Configuration

1. **Edit `.env`** — at minimum `TELEGRAM_BOT_TOKEN` and
   `TELEGRAM_ALLOWED_USERS` (details in
   [`../shared/telegram-setup.md`](../shared/telegram-setup.md)).
2. **`data/config.yaml`** is already prepared (copied from
   `config/config.yaml.example`): it points Hermes at
   `http://llama-server:8080/v1`, the neighboring service's name in
   `docker-compose.yml` — Docker Compose resolves that name automatically, no
   IP address to manage.

## Starting

```bash
docker compose up -d
docker compose logs -f llama-server
# wait for the line "server is listening on http://0.0.0.0:8080"
```

Then, **once**, wire up Telegram:

```bash
docker compose exec hermes hermes gateway setup
```

## Verification

```bash
# llama.cpp health
curl http://127.0.0.1:8080/health

# agent status
docker compose exec hermes hermes doctor

# agent logs
docker compose logs -f hermes
```

Then, on Telegram, send the bot a message: "can you hear me?". A reply
confirms the whole chain works (Telegram → hermes → llama-server → model →
back).

The web dashboard is available at `http://<vps-ip>:9119` if
`HERMES_DASHBOARD=1` (the default in `.env.example`) — make sure to protect
it behind a firewall or an SSH tunnel, it has no authentication of its own by
default.

## Common operations

```bash
docker compose restart hermes        # restarts just the agent
docker compose exec hermes hermes doctor --fix
docker compose logs --tail 100 llama-server
docker compose down                  # stop (data persists in ./data and ./models)
docker compose pull && docker compose up -d   # update images
```

## Alternative: native llama.cpp (prebuilt binary, no Docker)

If you'd rather not run `llama-server` in a container at all — e.g. to run
it as a plain systemd service, or to skip the `ghcr.io/ggml-org/llama.cpp`
image entirely — use the official prebuilt Linux binary instead, and keep
only `hermes` in Docker:

```bash
./scripts/download-prebuilt-llama-server.sh
# ==> Ready: .../vendor/llama.cpp-prebuilt/current/llama-server
```

See [`../shared/prebuilt-binaries.md`](../shared/prebuilt-binaries.md) for
what this binary actually contains (it auto-dispatches to the best CPU
microarchitecture at startup, so no manual `-march=native` tuning needed).

Run it directly for a quick test:

```bash
cd vendor/llama.cpp-prebuilt/current
./llama-server -m ../../../models/qwen2.5-coder-7b-instruct-q4_k_m.gguf \
  --host 127.0.0.1 --port 8080 -c 65536 -t 2 --jinja
```

Or install it as a persistent systemd service:

```bash
cp scripts/llama-server.service.example /etc/systemd/system/llama-server.service
# edit the REPLACE_WITH_REPO_PATH occurrences
systemctl daemon-reload
systemctl enable --now llama-server
```

Then start **only** the `hermes` container, using the alternate compose file
that resolves `host.docker.internal` to the VPS itself instead of a
`llama-server` service:

```bash
cp config/config.yaml.example.native-llama data/config.yaml
docker compose -f docker-compose.native-llama.yml up -d
docker compose -f docker-compose.native-llama.yml exec hermes hermes gateway setup
```

Don't run `docker-compose.yml` and `docker-compose.native-llama.yml` at the
same time — they both define a `hermes` container on the same ports.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `hermes` stays `starting` | `llama-server` hasn't finished loading the model yet — check `docker compose logs llama-server` |
| Tool calls come back as raw JSON text instead of running | The `--jinja` flag is missing from `docker-compose.yml` (already present here — verify if you changed it) |
| Slow / truncated responses | `LLAMA_CTX_SIZE` or `LLAMA_THREADS` poorly sized for the rented VPS — adjust in `.env` |
| The Telegram bot never replies | `TELEGRAM_ALLOWED_USERS` doesn't match your real user ID — revisit [`../shared/telegram-setup.md`](../shared/telegram-setup.md) |

## Sources

- Prebuilt binaries (what's inside, how they're fetched): [`../shared/prebuilt-binaries.md`](../shared/prebuilt-binaries.md)
- llama.cpp image and flags: [ggml-org/llama.cpp — docs/docker.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- Hermes image and volumes: [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- `custom` provider / `config.yaml`: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- Telegram variables: [hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
