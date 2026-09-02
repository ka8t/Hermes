# Hermes

Deployment of [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research's open-source, self-hosted AI agent) wired to a **local** LLM
served by [llama.cpp](https://github.com/ggml-org/llama.cpp) — no external
API key, no data sent to a third-party service, everything runs on hardware
you own or rent.

Two complete configurations, independent from each other:

| Configuration | Where | llama.cpp | Hermes | Guide |
|---|---|---|---|---|
| **macOS ARM64** | An Apple Silicon Mac | native (Metal acceleration) | Docker (`linux/arm64`) | [`macos-arm64/`](macos-arm64/) |
| **Linux x86-64** | A rented VPS | Docker (CPU) | Docker (`linux/amd64`) | [`linux-x86_64-vps/`](linux-x86_64-vps/) |

Both wire Hermes to Telegram (see
[`shared/telegram-setup.md`](shared/telegram-setup.md)), serve the same
model by default — **Qwen2.5-Coder-7B-Instruct** in `Q4_K_M` (see
[`shared/model-notes.md`](shared/model-notes.md) to change it) — and default
to llama.cpp's **official prebuilt binaries** rather than building from
source (see [`shared/prebuilt-binaries.md`](shared/prebuilt-binaries.md)).
The VPS guide also documents a no-Docker alternative for `llama-server`
using that same prebuilt binary as a systemd service.

## Why llama.cpp native on Mac but in Docker on the VPS?

Docker Desktop for Mac cannot expose the Metal GPU to a container — running
`llama-server` inside it would fall back to CPU-only inference. On a Mac, it
therefore runs natively (full Metal access), while only Hermes — which just
needs to call an HTTP API, no GPU required — runs in Docker. On a regular
Linux VPS (no dedicated GPU), this distinction doesn't apply: everything fits
cleanly inside `docker-compose.yml`, llama.cpp included.

## Why this default model?

Hermes requires at least 64,000 tokens of context to work properly (memory +
tools + history are sent on every call), and tool calls only execute with
llama.cpp's `--jinja` flag — both easy-to-miss points are explained and
already handled in both configurations. See
[`shared/model-notes.md`](shared/model-notes.md).

## Quick start

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes

# On an Apple Silicon Mac
cd macos-arm64 && cat README.md

# On a Linux x86-64 VPS
cd linux-x86_64-vps && cat README.md
```

## Repository structure

```
Hermes/
├── macos-arm64/          # native llama.cpp (Metal) + Hermes in Docker
├── linux-x86_64-vps/     # llama.cpp and Hermes, both in Docker Compose
│                         # (+ a no-Docker/systemd alternative for llama.cpp)
└── shared/
    ├── telegram-setup.md      # bot creation, environment variables
    ├── model-notes.md         # GGUF model choice, context constraints
    └── prebuilt-binaries.md   # official llama.cpp binaries, per platform
```

## Security

No secrets are committed: `.env` is git-ignored (only `.env.example` files
are tracked), as is any `.gguf` model (too large) and Hermes's persistent
state (`data/`, including memory and sessions). See `.gitignore`.

## Sources

- Hermes Agent — official repository: https://github.com/NousResearch/hermes-agent
- Official documentation: https://hermes-agent.nousresearch.com/docs/
- llama.cpp — official repository: https://github.com/ggml-org/llama.cpp
