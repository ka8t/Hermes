# Web dashboard

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

Hermes ships a built-in web UI, separate from Telegram — a control panel
for the deployment itself, reachable at `http://<host>:9119` once
`HERMES_DASHBOARD=1` (the default in both platforms' `.env.example`).

## What it's for

Confirmed from the installed UI's own source
(`/opt/hermes/web/src/pages/` inside the container, checked 2026-09-08):

| Page | What it shows/does |
|---|---|
| Chat | Talk to the agent directly from the browser, no Telegram needed |
| Sessions | Ongoing/past conversations |
| Cron | Scheduled jobs — e.g. the one `guided-demo.sh`'s prompt creates |
| Logs | Live gateway logs |
| Config / Env | This profile's config and environment variables |
| Skills / Profiles / Pairing | Agent skills, multi-user profiles, pairing approvals |
| Channels | Connection status per platform (Telegram, etc.) |
| System | Overall deployment status |
| Analytics, Models, Files, Webhooks, Plugins, Docs, ProfileBuilder | The rest of the admin surface |

Useful for checking what actually happened without depending solely on a
Telegram round-trip — e.g. confirming a cron job exists, reading logs
directly, or chatting with the agent when testing without a phone handy.

## Credentials are mandatory, not optional

`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` in `.env` — the
dashboard refuses to start at all without them once reachable from
outside `127.0.0.1`
([hermes-agent docs](https://github.com/NousResearch/hermes-agent),
fail-closed on non-loopback binds). Both platforms' `docker-compose.yml`
publish port 9119 on all interfaces (`"9119:9119"`, not
`"127.0.0.1:9119:9119"`) — on the **VPS this means genuinely
internet-facing** at the machine's public IP; put it behind a firewall
or an SSH tunnel as a second layer, don't rely on the password alone. On
**macOS** it's LAN-reachable (any device on the same network), not
internet-facing unless you've separately port-forwarded it.

`scripts/configure-env.sh` (both platforms, called from `provision.sh`)
sets these interactively.

## First real test run: reconfigure, don't silently keep

On a re-run against an already-configured deployment,
`configure-env.sh` shows *"Dashboard credentials already configured
(user: X)"* and asks *"Reconfigure them? [y/N]"* — defaulting to keep
the existing ones untouched.

If you're doing a real guided end-to-end test (per `start.sh`) and don't
already know the current password (never saved it, or it's from a much
earlier setup), answer **`y`** here rather than defaulting through: the
script offers to generate a secure password with `openssl rand -base64
24` and prints it once on screen — note it immediately. That gives you
working credentials to actually log into
`http://<host>:9119` and explore the dashboard yourself as part of the
same test, rather than an inaccessible admin panel with a password
nobody has.
