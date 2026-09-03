# Microsoft Teams setup

Unlike Telegram's polling, Teams delivers messages by calling a public
HTTPS webhook — this VPS needs a publicly reachable endpoint. Bot
registration goes through the `@microsoft/teams.cli` tool, not the Azure
portal directly.

Not yet verified against a real Microsoft/Azure AD tenant by this repo —
see "Status" at the bottom before relying on this in production.

## How the bot responds

| Context | Behavior |
|---|---|
| Personal chat (DM) | Responds to every message, no @mention needed |
| Group chat / channel | Only responds when @mentioned (Teams delivers this as `<at>BotName</at>`, which Hermes strips automatically) |

## 1. Expose the webhook publicly first

Teams needs the public URL *before* bot creation (step 3 below passes it
as `--endpoint`). This repo uses Cloudflare Tunnel — see
[`cloudflare-tunnel-setup.md`](cloudflare-tunnel-setup.md) and set it up
before continuing (route a public hostname to `hermes:3978`, matching
`TEAMS_PORT`'s default in `.env.example`). Teams terminates TLS at the
tunnel and expects plain HTTP forwarded to `3978` — the Cloudflare Tunnel
doc's routing table already reflects this.

## 2. Install the Teams CLI and log in

On your own machine (not necessarily the VPS — this is an interactive
Microsoft login):

```bash
npm install -g @microsoft/teams.cli@preview
teams login
teams status --verbose   # note your AAD object ID — needed for TEAMS_ALLOWED_USERS
```

## 3. Create the bot

```bash
teams app create \
  --name "Hermes" \
  --endpoint "https://<your-cloudflare-tunnel-hostname>/api/messages"
```

Save the printed `CLIENT_ID`, `CLIENT_SECRET` (shown once), and
`TENANT_ID`, plus the install link this command outputs.

## 4. Fill in `.env`

```bash
TEAMS_CLIENT_ID=<from step 3>
TEAMS_CLIENT_SECRET=<from step 3>
TEAMS_TENANT_ID=<from step 3>
TEAMS_ALLOWED_USERS=<your AAD object ID from step 2>
```

Restart:

```bash
docker compose up -d --force-recreate hermes
```

**Verify whether the Teams SDK actually loaded** before assuming this
works. Checked directly in `ghcr.io/ka8t/hermes` (2026-09-03): the
`microsoft_teams_apps` Python module is **not** pre-bundled in the image,
but `uv` (the tool the upstream lazy-install mechanism uses) **is**
present on `PATH` — so the documented "lazy-installs on first start when
`TEAMS_CLIENT_ID` is set" behavior is plausible but not yet confirmed to
actually trigger inside this specific image. Check `docker compose logs
hermes` for `Teams SDK missing` / `No adapter available for teams` after
setting `TEAMS_CLIENT_ID`; if it appears, this repo's `docker/Dockerfile`
needs `RUN uv pip install microsoft-teams-apps aiohttp` (or the `teams`
extra) added explicitly rather than relying on lazy-install. See
[issue #19](https://github.com/ka8t/Hermes/issues/19).

## 5. Install the app in Teams

```bash
teams app get <teamsAppId> --install-link
```

Open the printed link in a browser — it opens directly in the Teams
client. Send the bot a DM once installed; it's ready.

**Verify the listener actually came up**:

```bash
docker compose logs hermes | grep -i teams
# or: hermes gateway status -l   (native install)
```

Look for `[teams] Webhook server listening on * (all interfaces,
IPv4+IPv6):3978/api/messages`.

## Full configuration reference

### Environment variables

| Variable | Description |
|---|---|
| `TEAMS_CLIENT_ID` | Azure AD App (client) ID |
| `TEAMS_CLIENT_SECRET` | Azure AD client secret — rotate periodically via the Azure portal or Teams CLI |
| `TEAMS_TENANT_ID` | Azure AD tenant ID |
| `TEAMS_ALLOWED_USERS` | Comma-separated AAD object IDs allowed to use the bot |
| `TEAMS_ALLOW_ALL_USERS` | Set `true` to skip the allowlist entirely |
| `TEAMS_HOME_CHANNEL` | Conversation ID for cron/proactive message delivery |
| `TEAMS_HOME_CHANNEL_NAME` | Display name for the home channel |
| `TEAMS_PORT` | Webhook port (default `3978`) |

### Equivalent `config.yaml` form

```yaml
platforms:
  teams:
    enabled: true
    extra:
      client_id: "your-client-id"
      client_secret: "your-secret"
      tenant_id: "your-tenant-id"
      port: 3978
```

## Features

**Interactive approval cards**: a dangerous command sends an Adaptive
Card with four buttons instead of requiring `/approve` typed out — **Allow
Once**, **Allow Session**, **Always Allow**, **Deny**. Clicking one
resolves the approval inline and replaces the card with the decision.

**Meeting summary delivery** (only relevant if the separate
`teams_pipeline` plugin is enabled — out of scope for this repo today):
this same adapter can also deliver meeting-transcript summaries, via
either a static `incoming_webhook_url` (simple, no threading) or the
Microsoft Graph API (`delivery_mode: graph`, threaded posts under the
bot's own identity, needs a separate Graph app registration). Inert
unless that plugin is turned on.

## Production deployment

For a permanent (non-tunnel) setup, terminate TLS at a real reverse proxy
and forward to the plain HTTP listener (`http://127.0.0.1:3978` /
`hermes:3978`) — Teams rejects self-signed certificates and the local
listener never serves HTTPS itself. Point the bot at the new endpoint:

```bash
teams app update --id <teamsAppId> --endpoint "https://your-domain.com/api/messages"
```

(`teams app create` was for first registration in step 3; use `update`
once the app already exists — re-running `create` would register a
second bot.)

## Troubleshooting

| Symptom | What to check |
|---|---|
| `requirements not met` / `Teams SDK missing` / `No adapter available for teams` | Restart the gateway so lazy-install can run — see the SDK-bundling note above; may need `docker/Dockerfile` changes instead of relying on it |
| `health` endpoint works but bot never responds | The tunnel may have gone down, or its URL no longer matches what was registered with `teams app create`/`update` |
| Logs show `"UNKNOWN / HTTP/1.0" 400` | Something is forwarding HTTPS to the plain-HTTP listener — terminate TLS at the tunnel/proxy, forward HTTP to `3978` |
| `KeyError: 'teams'` in logs | Restart the container |
| Bot responds with auth errors | Re-check `TEAMS_CLIENT_ID`/`TEAMS_CLIENT_SECRET`/`TEAMS_TENANT_ID` — all three must be correct together |
| Bot receives messages but ignores them | Your AAD object ID isn't in `TEAMS_ALLOWED_USERS` — re-run `teams status --verbose` to confirm it |
| Tunnel URL changed after a restart | Cloudflare named tunnels (this repo's setup) keep a stable hostname — if it still changed, the tunnel wasn't configured as a named one; re-run `teams app update` with the current URL either way |
| Teams shows "This bot is not responding" | Check `docker compose logs hermes` / `hermes gateway status -l` for a traceback around the failed request |
| `[teams] Failed to connect` | SDK failed to authenticate — double-check the tenant ID matches the account used in `teams login` |

## Security

- **Always set `TEAMS_ALLOWED_USERS`.** Without it, anyone who finds or
  installs the bot can talk to it — messages from anyone else are
  silently dropped once it's set.
- **`TEAMS_CLIENT_SECRET` is a password.** Rotate it periodically.
- Store `.env` with `chmod 600` — same posture this repo already takes
  for Telegram/WhatsApp credentials.
- The public `/api/messages` endpoint is authenticated by the Teams Bot
  Framework itself — requests without a valid JWT are rejected before
  reaching Hermes.

## Status

Implemented (`.env.example`, this doc) but **not yet verified against a
real Microsoft/Azure AD tenant and a real message round-trip** — that
requires interactive Microsoft account access only the deploying user can
do, and the Teams-SDK-bundling question above is still open. Treat every
step as "should work per Microsoft's and Hermes's own documentation," not
"confirmed working," until someone completes it end-to-end and this note
is updated.

## Sources

- Official Hermes Microsoft Teams guide: [hermes-agent.nousresearch.com/docs/user-guide/messaging/teams](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/teams)
- `@microsoft/teams.cli`: [www.npmjs.com/package/@microsoft/teams.cli](https://www.npmjs.com/package/@microsoft/teams.cli)
