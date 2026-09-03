# Glossary

Central reference for acronyms and technical vocabulary used across this
repo's documentation (issue #40). **This is additive, not a replacement**
for the in-context explanations already in each doc — every term below
is still explained where it first appears in the doc you're reading;
this page is a quick-lookup summary for skimming or coming back later.

Alphabetical.

## API
Application Programming Interface — a defined way for one piece of
software to ask another to do something. This repo talks to llama.cpp
over an "OpenAI-compatible API" — the same request/response shape
OpenAI's own API uses, which most local-model tools have adopted as a
de facto standard.

## BFCL
Berkeley Function-Calling Leaderboard — a standardized, peer-reviewed
test suite for measuring how reliably a model calls tools/functions
correctly. See `shared/model-evaluation.md`.

## CLI
Command-Line Interface — a program you control by typing commands
(`hermes ...`, `git ...`) rather than clicking in a graphical window.

## Context window
The maximum amount of text (measured in tokens, see **Token**) a model
can "see" at once — its system prompt, tools, conversation history, and
the current message all have to fit inside it. See `shared/model-notes.md`.

## CPU / vCPU
Central Processing Unit — the general-purpose processor every computer
has. **vCPU** (virtual CPU) is the unit cloud/VPS providers sell you —
one vCPU is not always a full physical core, which is part of why real
measured performance can differ from what the core count alone suggests
(see `shared/hardware-sizing.md`).

## CUDA
NVIDIA's proprietary platform for running general-purpose computation on
their GPUs — the software layer llama.cpp uses to get GPU acceleration
on NVIDIA hardware. See `shared/gpu-setup.md`.

## GGUF
The file format llama.cpp loads models from — a single file bundling the
model's weights and metadata, usually **quantized** (see below) to
shrink it. This repo's default model ships as a `.gguf` file.

## GHCR
GitHub Container Registry — where this repo's own Docker image
(`ghcr.io/ka8t/hermes`) and third-party images it uses (like llama-swap's)
are hosted.

## GPU / GPU layers / offload
Graphics Processing Unit — hardware that can run a model dramatically
faster than a CPU for the parts of inference it's suited to.
"**Offloading**" a model means moving its computation layers onto the
GPU instead of the CPU; "**GPU layers**" (the `-ngl`/`--n-gpu-layers`
flag) controls how many of the model's layers get offloaded — `99` in
this repo's configs means "offload everything possible." See
`shared/gpu-setup.md` and `docs/ARCHITECTURE.md`.

## HTTP / HTTPS
HyperText Transfer Protocol (Secure) — the protocol web requests use.
Every API call in this repo (to llama-swap, to Telegram, to BFCL) is an
HTTP request; HTTPS is the encrypted version, needed for anything
exposed to the public internet (see `shared/cloudflare-tunnel-setup.md`).

## JSON
JavaScript Object Notation — a plain-text format for structured data
(`{"key": "value"}`), used everywhere in this repo: API request/response
bodies, config files, tool-call arguments.

## KV cache
"Key-value cache" — the working memory llama.cpp keeps while generating
text, so it doesn't have to recompute earlier tokens from scratch on
every new one. Its size scales with context length, which is part of why
a bigger context window costs more RAM/VRAM.

## LLM
Large Language Model — the actual AI model (e.g. Meta-Llama-3.1-8B) that
generates text and decides which tools to call. Hermes Agent is the
orchestrator around an LLM, not the LLM itself.

## Model handler
BFCL-specific term: the piece of code inside BFCL that knows how to
format prompts for, and parse responses from, one specific model family.
A model needs a registered handler before BFCL can evaluate it — see
`shared/model-evaluation.md`.

## Prefill
The step where a model reads and processes the entire prompt (system
prompt, tools, history) before generating its first output token. On
CPU-only hardware this can take minutes for a large prompt — see
`shared/telegram-setup.md` and `shared/hardware-sizing.md`.

## Profile (Hermes)
One independent identity/instance inside a single Hermes deployment —
its own memory, skills, and schedule, isolated from any other profile on
the same install. See `shared/multi-user-agents.md`.

## Quantization
Shrinking a model's numeric precision (e.g. from 16-bit to 4-bit numbers)
to reduce its file size and memory use, at some cost to accuracy. `Q4_K_M`
(this repo's default) is one specific quantization scheme among many —
see `shared/model-notes.md`.

## RAG
Retrieval-Augmented Generation — having a model search a document
collection for relevant information before answering, instead of relying
only on what it learned during training. Specced in this repo as a
two-tier corpus/collection model — see `shared/model-evaluation.md`'s
sibling design work in issues #21-#26.

## RAM / VRAM
Random-Access Memory — a computer's working memory. **VRAM** is the same
concept on a GPU, separate from and usually much smaller than system RAM
— a real constraint when deciding how many models can be loaded at once
(see `shared/model-comparison.md`'s `groups` configuration).

## ROCm
AMD's platform for running general-purpose computation on their GPUs —
the AMD equivalent of NVIDIA's CUDA. See `shared/gpu-setup.md`.

## Skill (Hermes)
A packaged, version-controlled procedure Hermes can follow — written
instructions (not code) that guide the model through a multi-step task,
like `skills/agent-creation/clarify-agent-intent`. Distinct from a
**tool**, which is a concrete function-calling capability (like
`terminal` or `web_search`).

## SQL
Structured Query Language — the standard language for querying/managing
relational databases. `llama-bench -o sql` outputs results in this
format, importable straight into SQLite — see `shared/model-evaluation.md`.

## SSO
Single Sign-On — logging into multiple systems with one shared
authentication step. Referenced in `shared/enterprise-safety.md` as a
capability this repo does **not** have (no delegated/SSO-gated approval
routing exists).

## SYCL
The cross-vendor programming model llama.cpp uses for Intel GPU
acceleration — the Intel equivalent of CUDA (NVIDIA) / ROCm (AMD). See
`shared/gpu-setup.md`.

## Token / tokens per second (tok/s)
A **token** is the unit a language model actually reads and writes in —
often close to a word, sometimes a word-fragment or punctuation mark, not
a fixed character count. **Tokens per second** measures real throughput:
how fast a model processes a prompt ("prompt processing" / "pp") or
generates a reply ("generation" / "tg") — see
`shared/hardware-sizing.md` and `scripts/verify-inference.sh`.

## Tool-calling / function-calling
A model's ability to say "call this specific function with these
arguments" in a structured way, instead of just replying with plain
text — how Hermes Agent lets a model search the web, run a command, or
check a calendar. BFCL specifically measures how reliably a model does
this correctly.

## TTL
Time To Live — how long something is kept before being discarded.
llama-swap's `ttl: 600` (in `models.yaml`) means a loaded model is
unloaded after 600 seconds of inactivity, freeing memory for another
model. See `shared/managing-models.md`.

## URL
Uniform Resource Locator — a web address (e.g.
`http://127.0.0.1:8080/v1/models`).

## VPS
Virtual Private Server — a rented virtual machine, this repo's Linux
deployment target (as opposed to a Mac you own).

## WABA
WhatsApp Business Account — the account type required to use the
WhatsApp Business Cloud API channel. See `shared/whatsapp-setup.md`.

## YAML
"YAML Ain't Markup Language" — the human-readable text format this
repo's config files use (`config.yaml`, `models.yaml`,
`docker-compose.yml`).
