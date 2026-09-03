# Project conventions

- **Language: English only.** All documentation (README files, files under
  `shared/`) and all comments in code, scripts, Dockerfiles, Compose files,
  `.env.example` files, and config templates must be written in English —
  regardless of the language used in conversation to work on this repo.
- Prose is factual and technical, no filler. Keep the existing structure of
  each README (prerequisites → install → configure → start → verify →
  troubleshooting → sources) when adding to it.
- Every non-obvious technical claim (a flag requirement, a platform
  limitation, a default value) should cite its source — official docs are
  linked at the bottom of each README.

## Agent skills

### Issue tracker

Issues are tracked as GitHub Issues on `ka8t/Hermes`, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout — `CONTEXT.md` and `docs/adr/` at the repo root, created lazily as decisions are made. See `docs/agents/domain.md`.

### Architecture document — mandatory, keep current

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is a living
description of the whole system — components, deployment topology per
platform, message/data flow, diagrams (Mermaid) — not a point-in-time
snapshot. **Any change that alters architecture (a new channel, a new
data flow, a new deployment path, a change to the multi-user routing
model, a new major dependency) must update this file in the same
change**, not as a follow-up. Treat it with the same non-negotiable
weight as the English-only rule above.
