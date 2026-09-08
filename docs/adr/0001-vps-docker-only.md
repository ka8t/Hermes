# ADR 0001: The VPS deployment is Docker-only

**Status**: Accepted, 2026-09-08.

## Context

On 2026-09-07, a fully native (no-Docker) path was added for the Linux
x86-64 VPS configuration: `provision.sh` gained an interactive
"Docker or native?" prompt, and six new scripts
(`install-hermes-native.sh`, `setup-hermes-native.sh`,
`patch-native-hermes.sh`, `download-prebuilt-llama-server.sh`,
`download-llama-swap.sh`, `run-llama-swap-native.sh`) plus a systemd
service template and a native `models.yaml` template were added to
`linux-x86_64-vps/`, mirroring the native path that already existed for
macOS.

Unlike on macOS — where the native path exists for a real hardware
reason (Docker Desktop cannot expose the Metal GPU to a container, so
`llama-server` must run natively to get GPU acceleration at all) — the
VPS has no such constraint. It's CPU-only either way; Docker adds no
performance penalty there. The native VPS path existed purely as an
alternative for operators who'd rather not run Docker at all, not to
unlock capability Docker couldn't provide.

That native VPS path was built, committed, and documented, but never
used for any real deployment: the actual reference VPS this project
tests against has run Docker throughout (confirmed live, 2026-09-08:
`docker compose ps` showed both containers up 14h+/22h+). It roughly
doubled the maintenance surface on that platform — every fix applied to
the Docker path (the `.env` symlink fix in issue #73, the SOUL.md
patches in #48/#50/#75/#76) needed a second, native-specific
implementation kept in sync by hand, exercised by nobody.

Separately, the project's working pattern going forward is to iterate
and validate changes on the Mac first (fast local feedback, Metal
acceleration, seconds not minutes per retest — see
`hermes_mac_fast_dev_platform` in project memory) before deploying the
same fix to the VPS. That pattern only needs one VPS target to deploy
to, not two.

## Decision

Drop the native VPS path entirely. The VPS supports Docker only.

- Removed: `provision.sh`'s interactive mode prompt and its native
  branch; the six native-only scripts; the native systemd service
  template; `config/models.yaml.example.native`; the "Native
  alternative" section and its scripts-reference entries from
  `linux-x86_64-vps/README.md`.
- Kept unchanged: macOS's native path (`macos-arm64/`), which remains
  fully supported for its original GPU-acceleration reason.
- Kept unchanged: the generic `HERMES_MODE=docker|native` convention in
  `eval/lib-hermes-env.sh` (used by both platforms) and in the VPS's own
  `silent-failure-watchdog.sh` (harmless to leave generic; there's simply
  no supported way to reach `native` mode on the VPS anymore).

## Consequences

- One deployment path per platform for the VPS (simpler guided
  `provision.sh` flow, nothing to keep in sync across two VPS
  mechanisms).
- Anyone who wants to run Hermes on a Linux box with no Docker at all
  has no supported path in this repo; the closest documented
  alternative is macOS's native path, or following the same pattern by
  hand from `git history` (the removed scripts are recoverable from
  the commit that deleted them, if this decision is ever revisited).
- `docs/ARCHITECTURE.md`, the root `README.md`, `linux-x86_64-vps/README.md`,
  and `shared/{single-env-file,hardware-sizing,multi-user-agents,telegram-setup}.md`
  were updated in the same change to stop describing a VPS native path.
