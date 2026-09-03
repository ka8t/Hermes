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

Use the install link from step 3 to add the bot to your own Teams client,
or share it with whoever should have access.

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
