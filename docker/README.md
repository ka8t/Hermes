# `ghcr.io/ka8t/hermes` — ready-to-run Hermes image

The vanilla `nousresearch/hermes-agent` image works fine on its own, but
starts with no skills beyond Hermes's own bundled set and no opinion on
approvals. This image is that same base, plus:

- **[Guided agent creation](../skills/agent-creation/)** — two bundled
  skills (`clarify-agent-intent`, `build-agent-from-intent`) that let you
  say "create an agent that watches my Reddit for AI news" and get a
  working, verified profile back, instead of hand-editing config. See
  [`../shared/managing-models.md`](../shared/managing-models.md) for the
  model side of that, and the skills themselves for the rest.
- **Two starting templates** — `content-watcher` and `email-triage` under
  [`../skills/agent-creation/templates/`](../skills/agent-creation/templates/) —
  concrete enough to be usable as-is, simple enough to copy and adapt.
- **An enterprise-safe approval default** — `approvals.mode: manual`, so no
  destructive action ever runs without an explicit human answer. See
  [`../shared/enterprise-safety.md`](../shared/enterprise-safety.md) for
  exactly what this does and does not cover (it does not add delegated/
  group/SSO approval — that's a real gap, tracked in
  [issue #4](https://github.com/ka8t/Hermes/issues/4), not silently
  assumed to work).

It does **not** bundle a model or llama-swap/llama-server — those need
platform-specific handling (Metal on Mac, plain CPU on a generic VPS) that
doesn't belong baked into one image. Point this container at whichever
llama-swap endpoint you're running, exactly as the
[`macos-arm64/`](../macos-arm64/) and [`linux-x86_64-vps/`](../linux-x86_64-vps/)
guides already do — this image only changes what ships inside Hermes
itself.

## Quickstart

If you already have a llama-swap endpoint running (either of this repo's
two guides gets you one), point Hermes at it exactly as documented there,
just swap the image name:

```yaml
services:
  hermes:
    image: ghcr.io/ka8t/hermes:latest   # instead of nousresearch/hermes-agent:latest
    # ... the rest is identical to macos-arm64/docker-compose.yml or
    # linux-x86_64-vps/docker-compose.yml, whichever platform you're on
```

Everything else — `.env`, `config.yaml`, `models.yaml`, the verification
steps — is exactly what's documented in this repo's two platform guides.
This image changes what's *inside* Hermes, not how you run or connect it.

## Building it yourself

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes
docker build -f docker/Dockerfile -t ghcr.io/ka8t/hermes:latest .
```

(build context must be the repo root — the Dockerfile's `COPY` paths are
relative to it, not to `docker/`)

## What's actually in it (verified, 2026-09-02)

Built and booted locally against a fresh volume before publishing:

- `docker/stage2-hook.sh` (part of the base image) syncs
  `/opt/hermes/skills/ka8t-hermes/agent-creation/*` into the running
  instance's live skills directory on every boot — confirmed in the boot
  log (`Syncing bundled skills... + build-agent-from-intent
  + clarify-agent-intent`).
- The `approvals.mode: manual` line, appended to the base image's own
  `cli-config.yaml.example`, is present in the actual `config.yaml`
  written on first boot — confirmed by inspecting the seeded file.

## CI

[`../.github/workflows/publish-image.yml`](../.github/workflows/publish-image.yml)
builds and pushes `ghcr.io/ka8t/hermes:latest` (and a commit-sha tag) on
every push to `main` that touches `docker/` or `skills/`.
