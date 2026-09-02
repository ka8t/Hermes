# Hermes

Deployment of [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research's open-source, self-hosted AI agent) wired to **local** LLMs
served by [llama.cpp](https://github.com/ggml-org/llama.cpp) — no external
API key, no data sent to a third-party service, everything runs on hardware
you own or rent. [llama-swap](https://github.com/mostlygeek/llama-swap) sits
between them so you can list more than one model and switch between them
from inside Hermes, rather than being locked to whatever was configured at
install time.

Two complete configurations, independent from each other:

| Configuration | Where | Model serving | Hermes | Guide |
|---|---|---|---|---|
| **macOS ARM64** | An Apple Silicon Mac | native (Metal acceleration) | Docker (`linux/arm64`) | [`macos-arm64/`](macos-arm64/) |
| **Linux x86-64** | A rented VPS | Docker (CPU) | Docker (`linux/amd64`) | [`linux-x86_64-vps/`](linux-x86_64-vps/) |

Both wire Hermes to Telegram (see
[`shared/telegram-setup.md`](shared/telegram-setup.md)), ship one model by
default — **Qwen2.5-Coder-7B-Instruct** in `Q4_K_M` (see
[`shared/model-notes.md`](shared/model-notes.md), and
[`shared/managing-models.md`](shared/managing-models.md) to add more) — and
default to official **prebuilt binaries** rather than building anything from
source (see [`shared/prebuilt-binaries.md`](shared/prebuilt-binaries.md)).
The Hermes web dashboard, when enabled, requires a real username/password
(it refuses to start without one — see each platform's README). Both also
ship [`ghcr.io/ka8t/hermes`](docker/) — the same Hermes, plus two bundled
skills that let you describe a new agent in plain language and get a
working profile back (see [`shared/managing-models.md`](shared/managing-models.md)
and [`skills/agent-creation/`](skills/agent-creation/)), and an
enterprise-safe approval default so nothing destructive ever runs without
an explicit human answer (see
[`shared/enterprise-safety.md`](shared/enterprise-safety.md)).

## Why native on Mac but in Docker on the VPS?

Docker Desktop for Mac cannot expose the Metal GPU to a container — running
`llama-server` inside it would fall back to CPU-only inference. On a Mac,
llama-swap and the `llama-server` it spawns therefore run natively (full
Metal access), while only Hermes — which just needs to call an HTTP API, no
GPU required — runs in Docker. On a regular Linux VPS (no dedicated GPU),
this distinction doesn't apply: everything fits cleanly inside
`docker-compose.yml`, model serving included.

## Why these defaults?

Hermes requires at least 64,000 tokens of context to work properly (memory +
tools + history are sent on every call), and tool calls only execute with
llama.cpp's `--jinja` flag — both easy-to-miss points are explained and
already handled in both configurations. See
[`shared/model-notes.md`](shared/model-notes.md). Every binary this repo
runs is fetched prebuilt rather than compiled, which means trusting each
project's CI pipeline rather than just its source — a trade-off made
deliberately, not overlooked; see the "Trust considerations" section of
[`shared/prebuilt-binaries.md`](shared/prebuilt-binaries.md).

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
├── macos-arm64/          # native llama-swap + llama.cpp (Metal) + Hermes in Docker
├── linux-x86_64-vps/     # llama-swap, llama.cpp and Hermes, all in Docker Compose
├── docker/               # ghcr.io/ka8t/hermes — Hermes + bundled skills + safe defaults
├── skills/agent-creation/  # the guided agent-creation skills + starter templates
└── shared/
    ├── telegram-setup.md      # bot creation, environment variables
    ├── model-notes.md         # GGUF model choice, context constraints
    ├── managing-models.md     # add / switch / remove models via llama-swap
    ├── prebuilt-binaries.md   # official binaries used, per platform
    └── enterprise-safety.md   # the approvals default, and what it doesn't cover
```

## Security

No secrets are committed: `.env` is git-ignored (only `.env.example` files
are tracked), as is any `.gguf` model (too large) and Hermes's persistent
state (`data/`, including memory, sessions, and the generated `config.yaml`
/ `models.yaml`). See `.gitignore`. Back up `data/` with `hermes backup`
before anything risky — see each platform's "Common operations".

## Sources

- Hermes Agent — official repository: https://github.com/NousResearch/hermes-agent
- Official documentation: https://hermes-agent.nousresearch.com/docs/
- llama.cpp — official repository: https://github.com/ggml-org/llama.cpp
- llama-swap — official repository: https://github.com/mostlygeek/llama-swap
