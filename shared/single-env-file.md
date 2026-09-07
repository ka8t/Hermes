# Single `.env` file (issue #73)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

**Status: fixed everywhere** — macOS (Docker and native) and the VPS
(Docker and native). The VPS Docker path took two attempts: a direct
bind-mount (like macOS) broke live production within seconds and was
reverted; a symlink-based approach fixed it properly. See "Why the VPS
Docker path needed a different mechanism" below — it's a real platform
difference worth understanding before touching either compose file
again, not just history.

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

## Why the VPS Docker path needed a different mechanism

**First attempt (reverted): the same direct bind-mount as macOS.**
Applying `./.env:/opt/data/.env` to `linux-x86_64-vps/docker-compose.yml`
and recreating the container on the VPS broke `docker compose` itself
within seconds:

```
open /home/debian/hermes/linux-x86_64-vps/.env: permission denied
```

**Root cause**: the `ghcr.io/ka8t/hermes` image's own boot-time setup step
(`cont-init.d/01-hermes-setup` → `/opt/hermes/docker/stage2-hook.sh`, the
`[stage2]` log lines) unconditionally `chown`s `$HERMES_HOME/.env` to its
internal runtime UID (`10000`) on **every container start, not just first
creation** — confirmed by reading the installed script directly:

```sh
# .env holds API keys and secrets — restrict to owner-only access. Applied
# unconditionally (not only on first-seed) so a host-mounted .env that was
# created with a permissive umask gets tightened on every container start.
if [ -f "$HERMES_HOME/.env" ]; then
    ...
    chown hermes:hermes "$HERMES_HOME/.env" 2>/dev/null || true
    chmod 600 "$HERMES_HOME/.env" 2>/dev/null || true
fi
```

On native Linux Docker (a VPS, no Docker Desktop), a bind-mounted file
shares the host's real UID space with no translation — so that chown
landed on the actual host file, turning it into `-rw------- 10000 10000
.env`, unreadable by the `debian` host user. Since `docker compose`
itself needs to read `env_file: .env` to do *anything* — including
`docker compose ps` — this locked out the tool that would normally fix
it. (Recovery, for reference: `docker compose exec` is *also* locked out
— plain `docker exec -u root hermes chown <host-uid>:<host-gid>
/opt/data/.env` works without needing host-level `sudo`.)

**Why the Mac didn't hit this**: Docker Desktop for Mac's virtiofs
bind-mount layer translates ownership between the container's view and
the host's real file — the container-side chown never reaches the actual
host inode. Confirmed directly: after the equivalent chown-on-every-boot
step ran on the Mac, `ls -la .env` on the host still showed `mac:staff`,
never the container's internal UID. That's a macOS/Docker-Desktop-specific
behavior, not a Docker guarantee — it makes the same bind-mount safe
there, not because the underlying mechanism is actually different.

**Second attempt (works): a symlink instead of a direct bind-mount.**
The same stage2-hook.sh has a guard that the first attempt never
triggered — reading further into the script surfaced it:

```sh
path_has_symlink_component() { ... if [ -L "$path" ]; then return 0; fi ... }
refuse_symlinked_path() {
    if path_has_symlink_component "$target"; then
        echo "[stage2] Warning: refusing $action through symlinked path $target — continuing"
        return 0
    fi
    return 1
}
```

If `$HERMES_HOME/.env` is a **symlink**, the chown/chmod above is skipped
entirely. Separately, `hermes-agent`'s own write path
(`save_env_value()` → `_write_env_lines()` → `atomic_replace()` in
`/opt/hermes/utils.py`) turned out to already handle this deliberately —
its docstring: *"Atomically move tmp_path onto target, preserving
symlinks. Resolves a symlink first so os.replace writes the real file in
place and the symlink survives."* So a symlinked `.env` survives both the
ownership-fix step and the wizard's own writes, by design on hermes-agent's
side, not by accident.

**Implementation**: `linux-x86_64-vps/docker-compose.yml` bind-mounts the
project `.env` to a **sibling** path, `/opt/data/.env.real`, instead of
directly onto `/opt/data/.env`:

```yaml
volumes:
  - ./data:/opt/data
  - ./.env:/opt/data/.env.real
```

`linux-x86_64-vps/provision.sh` creates `data/.env` as a symlink to
`.env.real` *before* the first `docker compose up -d` (so hermes-agent's
own first-boot seed step, which only fires when no file exists at that
path, never gets a chance to create a real one there). For a deployment
provisioned before this fix, the equivalent live-surgery on a running
container is: `docker exec -u root hermes sh -c "rm /opt/data/.env && ln
-s .env.real /opt/data/.env"`.

**Verified live on the VPS, 2026-09-07**:
- Container recreate (adding the `.env.real` mount only — doesn't touch
  `/opt/data/.env` itself, so no lockout risk during the switch): clean,
  host `.env` untouched.
- Symlink surgery via `docker exec -u root`: succeeded, content resolved
  correctly through the symlink from inside the container.
- **The actual test that matters**: `docker compose restart hermes`
  afterward — the exact operation that caused the lockout the first
  time. Logs showed `[stage2] Warning: refusing chown through symlinked
  path /opt/data/.env — continuing` (twice — the chown and the chmod),
  and the host `.env` stayed `debian:debian` throughout.
- A direct probe of the real write path — `docker exec -u root hermes
  python3 -c "from hermes_cli.config import save_env_value;
  save_env_value('TEST_SINGLE_ENV_PROBE', 'probe-ok')"` (the same
  function `hermes gateway setup` calls, exercised without touching real
  Telegram/API credentials) — wrote through to the real host `.env`, and
  the symlink survived the write (not replaced by a new regular file).
  Cleaned up via `remove_env_value()` immediately after.
- Telegram reconnected, dashboard responded normally throughout.

**macOS Docker mode stays on the direct bind-mount** (not switched to the
symlink pattern) — it already works there, verified across a recreate
and a plain restart, and there's no reason to add the extra indirection
where it isn't needed.

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
  write-through test, restart test) and the VPS (the reverted direct
  bind-mount and its lockout/recovery, then the symlink fix: recreate,
  live symlink surgery, restart test, and the `save_env_value()` write
  probe) — all direct observation, not assumed.
- `stage2-hook.sh` (installed inside `ghcr.io/ka8t/hermes`, read via
  `docker exec hermes cat /opt/hermes/docker/stage2-hook.sh`) and
  `hermes_cli/config.py` / `utils.py`'s `save_env_value()` /
  `_write_env_lines()` / `atomic_replace()` (read via `docker exec hermes
  grep ...` against the installed package) — the exact chown/chmod and
  symlink-preserving-write behavior quoted above came from reading this
  repo's own deployed image's source directly, not from upstream
  documentation (not otherwise documented as of hermes-agent 0.21.0).
