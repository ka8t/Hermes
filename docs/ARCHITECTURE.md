# Architecture

This repo is meant to be read, not just run — see `README.md`'s "What
this actually is" for the framing. This document is the detailed half of
that: components, deployment topologies, data flow, and — in section 6 —
an honest map of what's actually built versus only designed, so nothing
here is taken on faith.

Living document — **update this file in the same change** whenever
something here stops being true (a new channel, a new data flow, a new
deployment path, a change to routing/isolation, a new major dependency).
See `CLAUDE.md`'s "Architecture document" rule. Each section below notes
whether it describes something **live** (implemented and, where noted,
verified against a real deployment) or **specced** (issues exist,
nothing built yet).

Last updated: 2026-09-03.

See also: [Glossary](GLOSSARY.md) for acronyms/technical terms used below.

## Table of contents

- [1. System overview](#1-system-overview)
- [2. Deployment topologies (live)](#2-deployment-topologies-live)
- [3. Message flow (Telegram)](#3-message-flow-telegram--live-verified)
- [4. Multi-user profile isolation](#4-multi-user-profile-isolation-partially-live--5)
- [5. Enterprise safety (live)](#5-enterprise-safety-live)
- [6. Specced, not yet implemented](#6-specced-not-yet-implemented)
- [7. Repository structure](#7-repository-structure)
- [Sources](#sources)

## 1. System overview

Three kinds of pieces, always the same shape regardless of platform:

```mermaid
graph LR
    subgraph Channels["Gateways (live: Telegram · specced: WhatsApp #18 · Teams #19)"]
        TG[Telegram]
        WA[WhatsApp Cloud API]
        TM[Microsoft Teams]
    end

    subgraph Orchestrator["Hermes Agent"]
        H[gateway + agent loop<br/>memory · skills · tools]
    end

    subgraph Inference["Local model serving"]
        LS[llama-swap]
        LC[llama-server<br/>llama.cpp]
    end

    TG --> H
    WA -. specced .-> H
    TM -. specced .-> H
    H --> LS
    LS --> LC
    LC --> H
    H --> TG
    H -. specced .-> WA
    H -. specced .-> TM
```

- **Hermes Agent** ([github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)) holds memory, skills, and tool access; it does not itself generate text.
- **llama-swap** ([mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)) is a reverse proxy that loads/unloads `llama-server` processes on demand from `models.yaml`, enabling multiple models on one machine.
- **llama.cpp / llama-server** ([ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)) actually runs inference. No external API key anywhere in this path — see `shared/enterprise-safety.md` for what that guarantee does and doesn't cover.

## 2. Deployment topologies (live)

Two independent platform configurations, each with a Docker path and a
fully-native (no-Docker) path. See `README.md`'s comparison table and
each platform's own README for exact commands.

### 2.1 macOS (Apple Silicon)

```mermaid
graph TB
    subgraph Mac["Mac (native process)"]
        LSm[llama-swap] -->|spawns| LCm["llama-server<br/>(Metal, -ngl 99)"]
    end
    subgraph DockerD["Docker Desktop (optional — Hermes can also run native)"]
        Hd[hermes container<br/>linux/arm64]
    end
    Hn[hermes native process]

    TGm[Telegram] --> Hd
    TGm --> Hn
    Hd -->|host.docker.internal:8080| LSm
    Hn -->|127.0.0.1:8080| LSm
```

Metal acceleration requires `llama-server` to run natively — Docker
Desktop for Mac cannot expose the Metal GPU to a container, so
llama-swap/llama-server never run in Docker on this platform, regardless
of whether Hermes itself does.

### 2.2 Linux x86-64 VPS

```mermaid
graph TB
    subgraph DockerV["Docker Compose path (default)"]
        LSv["llama-swap container<br/>ghcr.io/mostlygeek/llama-swap:cpu"] -->|spawns| LCv[llama-server]
        Hv[hermes container] -->|llama-swap:8080| LSv
    end
    subgraph NativeV["Native path (no Docker at all)"]
        LSvn[llama-swap process] -->|spawns| LCvn[llama-server]
        Hvn[hermes native process] -->|127.0.0.1:8080| LSvn
    end
    CF["cloudflared<br/>(specced, #17 — only for WhatsApp/Teams)"]

    TGv[Telegram] --> Hv
    TGv --> Hvn
    CF -. specced .-> Hv
```

No GPU assumed by default (`:cpu` image tag) — see `shared/prebuilt-binaries.md`
and issue #13 (specced) for GPU detection/support.

## 3. Message flow (Telegram — live, verified)

```mermaid
sequenceDiagram
    participant U as User's phone
    participant TG as Telegram Bot API
    participant GW as Hermes Telegram gateway
    participant AL as Agent loop
    participant LS as llama-swap
    participant LC as llama-server

    U->>TG: message
    TG->>GW: poll (long-polling, no public endpoint needed)
    GW->>AL: dispatch
    AL->>LS: POST /v1/chat/completions<br/>(system prompt + skills + tools + history)
    LS->>LC: spawn/reuse model process
    LC-->>LS: streamed tokens (or tool_calls)
    LS-->>AL: streamed response
    AL->>AL: run tool if requested, update memory
    AL->>GW: final reply
    GW->>TG: sendMessage / editMessageText
    TG->>U: reply
```

**Known hardware-dependent latency**: on a CPU-only VPS, the prefill step
(reading the ~15-40KB system prompt before the first token) can take
20-40+ minutes depending on real thread/memory-bandwidth availability —
see `shared/model-notes.md` and `shared/telegram-setup.md`. Mandatory
follow-up: issue #27 (benchmark real inference throughput during
provisioning, not just detect specs) — see memory note
`hermes_hardware_inference_verification`.

**WhatsApp/Teams (specced, #18/#19)** differ structurally: both are
webhook-delivered (Meta/Microsoft call this deployment over HTTPS),
requiring the Cloudflare Tunnel infrastructure in #17 — Telegram's
polling model needs none of that.

## 4. Multi-user profile isolation (partially live — #5)

**Live**: `linux-x86_64-vps/scripts/build-agent-template.sh` and
`provision-user.sh` exist and are verified to correctly manipulate
config/create profiles (tested with synthetic identifiers — see commit
history). **Not yet live** with a real second user, since the current
deployment only has one allowed Telegram user.

```mermaid
graph TB
    B["One shared bot token<br/>(gateway.multiplex_profiles: true)"]
    R{gateway.profile_routes<br/>match on platform + chat_id}
    P1["Profile: default<br/>own memory, skills, cron"]
    P2["Profile: alice<br/>own memory, skills, cron"]
    P3["Profile: agent-template<br/>(clone source, not user-facing)"]

    B --> R
    R -->|no match| P1
    R -->|telegram:987654321| P2
    P3 -.->|--clone-from| P2
```

Isolation is structural (separate profile directories/state), not a
filter — see `shared/multi-user-agents.md` for the alternatives
considered and rejected (a shared-table filter, an in-chat admin/user
command split) and why.

## 5. Enterprise safety (live)

`approvals.mode: manual` is set in every config template in this repo —
every dangerous action always asks a human, no auto-approval regardless
of Hermes's own default `smart` mode. See `shared/enterprise-safety.md`
for exactly what this does and does not cover (notably: **no
delegated/group/SSO approval routing exists** — tracked as issue #4,
explicitly not assumed to work; and **`hermes -z`/`--oneshot` always
auto-bypasses every dangerous-command check, unconditionally, by
design** — confirmed live in issue #38, corrected in
`shared/enterprise-safety.md` 2026-09-03).

## 6. Specced, not yet implemented

Tracked in GitHub issues on `ka8t/Hermes` — do not treat any of this as
built until its issue is closed and this section is updated. This table
states only the current status; full evidence and history live in the
linked `shared/*.md` file or the issue itself.

| Feature | Issues | Status | Details |
|---|---|---|---|
| WhatsApp Cloud API / Microsoft Teams channels | #16-#20 | Implemented, not live-verified (needs the admin's own Meta/Microsoft accounts) | — |
| Hardware auto-detection (CPU/GPU) + inference benchmark | #11, #15 | Live on Docker + native VPS; GPU path live but not verified (no matching hardware); mandatory throughput benchmark live-tested on CPU VPS and M1 Mac | `shared/hardware-sizing.md` |
| Enterprise RAG (Google Drive, Confluence, SharePoint) | #21-#26, #33 | Specced only, nothing built | issues #21-#26 |
| Model/config evaluation harness | #28-#32 | BFCL containerized and scored (`simple_python` 54.75%, `parallel` 52.50%); throughput benchmarking and continuous re-evaluation still specced only | `shared/model-evaluation.md` |
| Instant message-received acknowledgment | #34 | Specced only | — |
| Global (cross-profile) stats/logs/KPI dashboard | #35 | Per-profile stats live; cross-profile admin aggregation unbuilt | — |
| Deployment scripts ported from bash to Rust | #36 | Specced only | — |
| In-channel multi-model comparison (`/compare`) | #39 | Specced only | `shared/model-comparison.md` |
| Agentic goal-drift, hallucinated success, silent failure | #37 (closed), #48 (open, stopgap shipped), #55 (closed), #56 (open) | #37 fixed with an automated regression gate; #48's root cause needs an upstream `hermes-agent` fix ([reported](https://github.com/NousResearch/hermes-agent/issues/102977)) — a local disclaimer stopgap ships in the meantime, validated 3/3 on real delegation runs; #55 found no model swap fixes it; #56 is a distinct silent-failure mode, not yet root-caused | `shared/model-notes.md` |
| `web_search` tool-name collision with llama-server | #50 | **Fixed** — llama-server hardcodes name-based handling for any tool called `web_search`; fixed by dropping the `limit` parameter from this repo's schema | `shared/model-notes.md` |
| `single_query_mode` approval-bypass verification | #38 | **Resolved** — `hermes -z` always bypasses approvals by design; this repo's own docs had conflated it with `single_query_mode`, now corrected | `shared/enterprise-safety.md` |

## 7. Repository structure

See `README.md`'s "Repository structure" section for the file-level map;
this document is about behavior and data flow, that one is about where
things live on disk.

## Sources

Every architectural claim above traces to either this repo's own
verified testing (commit history, issue discussions) or the official
docs already cited throughout `shared/*.md` — this file summarizes and
diagrams, it does not introduce new unverified claims of its own.
