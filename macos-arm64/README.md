# Hermes Agent + llama.cpp — macOS Apple Silicon (ARM64)

`llama-server` runs **natively** on the Mac to take advantage of **Metal** GPU
acceleration — Docker Desktop for Mac cannot expose the Metal GPU to a
container (the Linux containers it runs have no access to it), so running it
in Docker would fall back to CPU-only inference, defeating the purpose.
**Hermes**, on the other hand, doesn't need a GPU (it's just the harness that
calls the model over HTTP): it runs in a `linux/arm64` Docker container and
reaches `llama-server` via `host.docker.internal`.

```
┌─────────────────────────────── Mac (Apple Silicon) ───────────────────────────────┐
│                                                                                    │
│   llama-server (native, Metal)         http://host.docker.internal:8080/v1        │
│   scripts/run-llama-server.sh  ◄─────────────────────────────────┐                │
│         │                                                        │                │
│         ▼                                                ┌───────┴───────┐        │
│    .gguf model (./models)                                │ Docker Desktop│        │
│                                                            │  ┌─────────┐  │        │
│                                                            │  │ hermes  │  │        │
│                                                            │  │(arm64)  │  │        │
│                                                            │  └────┬────┘  │        │
│                                                            └───────┼───────┘        │
│                                                                    ▼                │
│                                                        ./data (memory, skills)      │
└────────────────────────────────────────────────────────────────────────────────────┘
                                                                     │
                                                                     ▼
                                                              Telegram (bot)
```

## Prerequisites

- An Apple Silicon Mac (M1/M2/M3/M4...).
- [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) — only used for the `hermes` container.
- Xcode Command Line Tools + CMake, **only** if no `llama-server` is already
  available on the machine (`xcode-select --install`, `brew install cmake`).
- A Telegram bot — see [`../shared/telegram-setup.md`](../shared/telegram-setup.md).

> This repo knows how to reuse an already-built `llama-server` — see
> [`scripts/find-or-build-llama-server.sh`](scripts/find-or-build-llama-server.sh):
> it checks `LLAMA_SERVER_BIN`, then `~/Documents/Code/llama.cpp/build/bin/llama-server`,
> then `brew install llama.cpp`, and only clones/builds into `./vendor` as a last resort.

## Installation

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes/macos-arm64
cp .env.example .env
```

Edit `.env`: at minimum `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS`
(details in [`../shared/telegram-setup.md`](../shared/telegram-setup.md)).

```bash
./scripts/download-model.sh          # downloads the default model into ./models
mkdir -p data
cp config/config.yaml.example data/config.yaml
```

## Starting

**Terminal 1 — the model, natively:**

```bash
./scripts/run-llama-server.sh
# ==> Binary: /Users/xxx/Documents/Code/llama.cpp/build/bin/llama-server (or freshly built)
# ==> Model : .../models/qwen2.5-coder-7b-instruct-q4_k_m.gguf
# ggml_metal_device_init: GPU name: Apple M...
# server is listening on http://127.0.0.1:8080
```

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
curl http://127.0.0.1:8080/health          # llama-server
docker compose exec hermes hermes doctor   # hermes
```

On Telegram, send the bot a message: "can you hear me?". A reply confirms
the whole chain works: Telegram → hermes container →
`host.docker.internal:8080` → `llama-server` (Metal) → model → back.

## Running `llama-server` in the background (optional)

To avoid keeping a terminal open at all times, a `launchd` service template
is provided:

```bash
cp scripts/com.hermes.llama-server.plist.example \
   ~/Library/LaunchAgents/com.hermes.llama-server.plist
# edit the 3 occurrences of REPLACE_WITH_REPO_PATH in that file
launchctl load ~/Library/LaunchAgents/com.hermes.llama-server.plist
```

Logs: `tail -f macos-arm64/llama-server.log`. To stop it:
`launchctl unload ~/Library/LaunchAgents/com.hermes.llama-server.plist`.

## Common operations

```bash
docker compose restart hermes
docker compose exec hermes hermes doctor --fix
docker compose down                        # stops hermes (./data and ./models persist)
```

## Troubleshooting

| Symptom | What to check |
|---|---|
| `Connection refused` from the hermes container | `llama-server` isn't running, or bound to the wrong interface — check `./scripts/run-llama-server.sh` in terminal 1 |
| Very slow replies / all-CPU | Verify the binary in use was actually built with `GGML_METAL=ON` (`grep METAL` in its `CMakeCache.txt`, or the startup logs should mention `ggml_metal_device_init`) |
| Tool calls come back as JSON text instead of running | The `--jinja` flag is missing when launching `llama-server` (already included in `run-llama-server.sh`) |
| `docker: no matching manifest for linux/arm64` | Stale cached `hermes-agent` image — `docker compose pull` |

## Sources

- llama.cpp Metal support: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- Hermes image and volumes (multi-arch amd64/arm64 confirmed on Docker Hub): [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- `custom` provider / `config.yaml`: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- `host.docker.internal` on Docker Desktop for Mac: [official Docker documentation](https://docs.docker.com/desktop/networking/)
