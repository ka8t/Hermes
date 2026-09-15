# Minimal runtime for the official prebuilt llama-server binary
# (../scripts/download-prebuilt-llama-server.sh bind-mounts it in at
# ./vendor/llama.cpp-prebuilt/current — nothing is COPYed into this
# image, so a binary update needs no rebuild, just a re-download and
# `docker compose up -d llama-server`).
#
# Replaces ghcr.io/mostlygeek/llama-swap:cpu (2026-09-15, issue #101):
# that image bundled the same official binary, but as a separate
# container with its own update lifecycle that nothing in this repo's
# deploy scripts tracked — the VPS silently ran a two-week-stale
# llama-server through a real incident because of it. This deployment
# never uses llama-swap's actual differentiator (multiple models loaded
# on demand) — a single model, always loaded, never swapped — so a plain
# runtime for the same binary loses nothing this repo relies on.
#
# ubuntu:24.04 matches the base the old image was confirmed built on
# (see ../../shared/prebuilt-binaries.md) — same glibc/libstdc++ ABI the
# official ubuntu-x64 release asset is built against.
FROM ubuntu:24.04

# ca-certificates: TLS trust store (unused at runtime here — no outbound
# HTTPS once a model is loaded locally — kept only in case a future
# --hf-repo flag needs it). curl: this Dockerfile's own HEALTHCHECK.
# libgomp1: llama.cpp's CPU backend uses OpenMP for multi-threading.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libgomp1 \
    && rm -rf /var/lib/apt/lists/*

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=20 \
    CMD curl -sf http://localhost:8080/health || exit 1
