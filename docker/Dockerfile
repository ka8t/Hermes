# Ready-to-run Hermes Agent image: the upstream image, plus this repo's
# guided agent-creation skills and an enterprise-safe approval default.
#
# What this does NOT bundle: a model, or llama-swap/llama-server — those
# stay separate services (see ../macos-arm64/ and ../linux-x86_64-vps/),
# because they need platform-specific handling (Metal on Mac, CPU on a
# generic VPS) that doesn't belong baked into one image. Point this
# container's config.yaml at whichever llama-swap endpoint you're running,
# exactly as documented for the vanilla image — this Dockerfile only adds
# skills and a safer default, it doesn't change how Hermes is configured.
#
# Build: docker build -f docker/Dockerfile -t ghcr.io/ka8t/hermes:latest .
# (build context must be the repo root, so COPY ../skills below resolves)
FROM nousresearch/hermes-agent:latest

# --- Bundled skills (see ../skills/agent-creation, ../skills/reliability) ---
# ../skills/reliability holds two skills: verify-before-success (#49) and
# web-search-query-only (#50, a confirmed llama-server bug workaround).
# Synced into every deployment's live skills directory automatically by the
# base image's own boot sequence (docker/stage2-hook.sh's skills_sync.py,
# confirmed by inspecting nousresearch/hermes-agent:latest) — nothing else
# needed here for the skills themselves to take effect.
COPY skills/agent-creation /opt/hermes/skills/ka8t-hermes/agent-creation
COPY skills/reliability /opt/hermes/skills/ka8t-hermes/reliability

# --- web_search schema fix (#50) ---
# llama-server's tool-call validation only accepts a schema's *required*
# properties, silently rejecting any call that includes a declared
# *optional* one — confirmed upstream bug, filed at
# https://github.com/ggml-org/llama.cpp/issues/28340. The base image's
# own web_search tool declares "limit" as optional (only "query" is
# required), and the model routinely includes "limit" anyway (its
# description invites it: "Defaults to 5"), so every such call was
# rejected with a 500 — confirmed live, deterministically, including as
# this model's very first move on issue #37's regression prompt. Making
# "limit" required sidesteps the llama-server bug entirely: grammar-
# constrained decoding then always includes it, which llama-server
# always accepts. See shared/model-notes.md.
RUN sed -i 's/"required": \["query"\]/"required": ["query", "limit"]/' \
    /opt/hermes/tools/web_tools.py

# --- Enterprise-safe approval default ---
# Appended (not replacing) the base image's own reference config, which the
# base image's first-boot seed copies verbatim into a fresh deployment's
# config.yaml — see shared/enterprise-safety.md for exactly what this does
# and does not cover. Every dangerous action requires an explicit human
# answer; it does not add delegated/group/SSO approval (Hermes has no such
# mechanism today — tracked separately, see that doc).
RUN printf '\n# --- ka8t/Hermes enterprise-safe default (see shared/enterprise-safety.md in github.com/ka8t/Hermes) ---\napprovals:\n  mode: manual\n' \
    >> /opt/hermes/cli-config.yaml.example
