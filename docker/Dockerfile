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
# llama-server has hardcoded, name-based special handling for any tool
# literally called "web_search": it validates the call against its own
# internal query-only contract regardless of what schema the client (us)
# actually declares for that name — confirmed directly via `strings` on
# the compiled llama-server binary (contains both the literal string
# "web_search" and the generic JSON-schema-validator error vocabulary
# right next to it), and via direct A/B testing against the live server
# (identical schema, different tool name: succeeds; "web_search" name,
# any second property: rejected, regardless of required/optional). An
# earlier attempt at this fix — making "limit" required instead of
# optional — did NOT work, because the collision is on the tool *name*,
# not on which properties are required; corrected here. Renaming the
# tool itself was considered and rejected: several of the base image's
# own bundled skills instruct the model to call "web_search" by that
# exact name, and renaming would silently break all of them. Removing
# "limit" from the schema entirely keeps the name and the default
# 5-result behavior, just without the model's ability to request a
# different count. See shared/model-notes.md and
# docker/patch-web-search-schema.py for the exact patch.
COPY docker/patch-web-search-schema.py /tmp/patch-web-search-schema.py
RUN python3 /tmp/patch-web-search-schema.py && rm /tmp/patch-web-search-schema.py

# --- Enterprise-safe approval default ---
# Appended (not replacing) the base image's own reference config, which the
# base image's first-boot seed copies verbatim into a fresh deployment's
# config.yaml — see shared/enterprise-safety.md for exactly what this does
# and does not cover. Every dangerous action requires an explicit human
# answer; it does not add delegated/group/SSO approval (Hermes has no such
# mechanism today — tracked separately, see that doc).
RUN printf '\n# --- ka8t/Hermes enterprise-safe default (see shared/enterprise-safety.md in github.com/ka8t/Hermes) ---\napprovals:\n  mode: manual\n' \
    >> /opt/hermes/cli-config.yaml.example
