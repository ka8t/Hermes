# Single `.env` file (issue #73)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

**Status: fixed on macOS (both Docker and native), fixed on the VPS native
path, still open on the VPS Docker path** — tried live on the VPS,
2026-09-07, and reverted after it broke `docker compose` itself. See "Why
the VPS Docker path is different" below before assuming this is uniform
across platforms.

Where it's fixed: exactly **one** `.env` file at the project root
(`macos-arm64/.env` or `linux-x86_64-vps/.env`) — both Docker Compose's
`env_file:` mechanism and hermes-agent's own credential wizards (`hermes
gateway setup`, `hermes config set`, etc.) read from and write to that
same file, with nothing left to keep in sync.

## The problem this used to be

hermes-agent (the upstream engine) has its own idea of where its `.env`
lives: `$HERMES_HOME/.env`, hardcoded in its own `save_env_value()` — not
configurable, not the same path this repo's own `env_file:` directive
points Docker Compose at.

- **Docker mode**: `$HERMES_HOME` resolves to `/opt/data` inside the
  container, bind-mounted from this platform's `./data/` directory on the
  host — so hermes-agent's wizards were writing to `./data/.env`, a
  completely separate file from the project root `.env` that
  `docker-compose.yml`'s `env_file:` actually loads into the container's
  process environment.
- **Native mode**: `setup-hermes-native.sh` used to `cp .env
  "${HERMES_HOME}/.env"` **once**, on first setup, and never again — so
  `~/.hermes/.env` started as a copy of the project `.env` but diverged
  the moment either file changed afterward. Same problem, different
  mechanism (a stale copy instead of a live bind-mount).

**Confirmed live, 2026-09-07**: `hermes gateway setup` reported
`TELEGRAM_HOME_CHANNEL` as set, but the project root `.env` — the file
this repo's own docs, scripts, and `docker-compose.yml` all treat as *the*
config — still showed it empty. The wizard had written the real value to
`data/.env` instead. Anyone editing only the project `.env` (as every
guide in this repo tells you to) would silently lose any value the wizard
itself sets.

## The fix

**macOS Docker mode**: `macos-arm64/docker-compose.yml` bind-mounts the
project `.env` file directly onto `/opt/data/.env`, in addition to the
existing `./data` directory mount:

```yaml
volumes:
  - ./data:/opt/data
  - ./.env:/opt/data/.env
```

Docker layers a more specific single-file mount on top of a broader
directory mount at the same path — standard Compose behavior, not a
special case. Verified live on the Mac deployment, 2026-09-07:

- Recreating the container after adding this mount: no errors, Telegram
  reconnected (`Connected to Telegram (polling mode)`), dashboard
  authentication unaffected.
- A write from inside the container (`echo >> /opt/data/.env`) appeared
  immediately on the host's `.env` — confirmed genuinely the same file,
  not a copy, no permission friction from the container's internal
  non-root `hermes` user.
- `TELEGRAM_HOME_CHANNEL` now reads correctly from both sides — the exact
  bug above no longer reproduces.
- A plain `docker compose restart hermes` afterward left the host-side
  `.env` still owned `mac:staff`, mode `600` — no ownership change, no
  lockout. Contrast with the VPS below.

**Native mode, both platforms**: `setup-hermes-native.sh` symlinks
instead of copying:

```bash
ln -s "$(pwd)/.env" "${HERMES_HOME}/.env"
```

Same effect as the Docker bind-mount — one file, two paths to it, nothing
to keep in sync — without needing a Docker-specific mechanism. The script
detects and refuses to silently overwrite a **pre-existing regular file**
at `${HERMES_HOME}/.env` (e.g. from an older, cp-based setup) — it prints
instructions to merge any values that file has and this directory's
`.env` doesn't, rather than risk discarding something like a
provider API key you'd configured there directly.

## Why the VPS Docker path is different (tried and reverted, 2026-09-07)

Applying the exact same bind-mount to `linux-x86_64-vps/docker-compose.yml`
and recreating the container on the production VPS broke `docker compose`
itself within seconds:

```
open /home/debian/hermes/linux-x86_64-vps/.env: permission denied
```

**Root cause**: the `ghcr.io/ka8t/hermes` image's own boot-time setup step
(`cont-init.d/01-hermes-setup`, the `[stage2]` log lines) normalizes
ownership under `/opt/data` to its internal runtime UID (`10000`) — and it
does this on **every container start, not just first creation**: a plain
`docker compose restart hermes` re-triggered it. On native Linux Docker (a
VPS, no Docker Desktop), a bind-mounted file shares the host's real UID
space with no translation — so that chown landed on the actual host file,
turning it into `-rw------- 10000 10000 .env`, unreadable by the `debian`
host user. Since `docker compose` itself needs to read `env_file: .env`
to do *anything* — including `docker compose ps` — this locked out the
tool that would normally fix it.

**Why the Mac didn't hit this**: Docker Desktop for Mac's virtiofs
bind-mount layer translates ownership between the container's view and
the host's real file — the container-side chown never reaches the actual
host inode. Confirmed directly: after the equivalent chown-on-every-boot
step ran on the Mac, `ls -la .env` on the host still showed `mac:staff`,
never the container's internal UID. That's a macOS/Docker-Desktop-specific
behavior, not a Docker guarantee — it happens to make the same bind-mount
safe there, not because the underlying mechanism is actually different.

**Recovery** (for reference, should this recur): `docker compose exec`
was *also* locked out (same env_file read). Plain `docker exec -u root
hermes chown <host-uid>:<host-gid> /opt/data/.env` fixed it without
needing host-level `sudo`, since root inside the container can chown a
bind-mounted file to any UID on a non-remapped Linux Docker install.

**Current state**: `linux-x86_64-vps/docker-compose.yml` does **not**
bind-mount `.env` — reverted to the original `./data:/opt/data`-only
mount, so this platform keeps the two-file (`data/.env`) architecture for
Docker mode specifically, for now. The one-time value merge (real
`TELEGRAM_HOME_CHANNEL` and `API_SERVER_KEY` copied into the project
`.env`) was kept — that part is safe and doesn't depend on the bind-mount.
**Native mode on the VPS is unaffected** by any of this (no container, no
UID translation question) — the symlink fix applies there exactly as on
macOS.

This is an open problem, not a closed one: eliminating the two-file split
for VPS Docker specifically would need a mechanism that survives the
image's own per-boot ownership step (e.g. an ACL granting the host user
access regardless of primary ownership, or redirecting `HERMES_HOME` to a
path outside `/opt/data`'s ownership-normalization scope) — not
attempted yet, and not something to improvise live against production
again. Worth a proper design pass (this repo's own grilling-based spec
process) before a second attempt.

## A file, not a purely duplicated one: what actually lives in it

Before this fix, `data/.env`/`~/.hermes/.env` wasn't *only* a stale copy
of the project `.env` — hermes-agent ships its own ~400-line reference
`.env` template (every supported LLM provider and channel, mostly
commented out) as the starting content for that file, then appends or
edits a handful of active keys on top of it (confirmed live: an
auto-generated `API_SERVER_KEY`, plus whatever the setup wizard writes).
None of that template content is required for hermes-agent to run — it's
documentation for a human editing the file by hand, and hermes-agent
reads specific env var *names* at runtime, not the file's comment
structure. Migrating to the project's much smaller `.env` (and
`.env.example`) as the single source doesn't lose anything hermes-agent
actually needs; it only drops the unused provider-reference comments,
which this repo's own `.env.example` already covers for the providers
this deployment actually uses.

One value is genuinely generated by hermes-agent itself and worth
preserving explicitly rather than letting it regenerate: `API_SERVER_KEY`
(an internal secret, read directly from the file by hermes-agent's own
loader — never exposed as a Docker Compose env var on its own, confirmed
by inspecting the running container). Both platforms' `.env.example`
now carry a note about this, and both project `.env` files were
migrated to include the current value that was live at the time of this
fix rather than letting hermes-agent mint a fresh one and potentially
invalidate anything already relying on the existing key.

## A benign startup warning you may see

```
[stage2] Warning: API_SERVER_KEY is set in both the container environment
and /opt/data/.env — the .env value wins at runtime (loaded with
override=True)
```

Expected, not an error: since `API_SERVER_KEY` now lives in the project
`.env`, Docker Compose's `env_file:` mechanism also injects it as a
container environment variable — and hermes-agent's own file-based loader
sees the *same* value in the bind-mounted file and prefers it
(`override=True`). Both sources agree because they're reading the same
underlying value; nothing to fix.

## Sources

- This repo's own live testing, 2026-09-07 — Mac Docker mode (recreate,
  write-through test, restart test) and the production VPS (bind-mount
  attempt, the resulting `docker compose` lockout, and its recovery/
  revert) — all direct observation, not assumed.
- hermes-agent's `save_env_value()` / `load_hermes_dotenv()` behavior —
  found by inspecting the running container's file layout and startup
  logs in this repo's own testing, not from upstream documentation (not
  otherwise documented as of hermes-agent 0.21.0).
