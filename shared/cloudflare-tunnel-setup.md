# Cloudflare Tunnel setup (public HTTPS for WhatsApp / Microsoft Teams)

Telegram polls Telegram's servers for new messages — nothing on this VPS
needs to be reachable from the internet. WhatsApp Business Cloud API and
Microsoft Teams work the other way around: Meta/Microsoft call **your**
server over HTTPS whenever a message arrives, each on its **own** local
port — `WHATSAPP_CLOUD_WEBHOOK_PORT` (default `8090`) and `TEAMS_PORT`
(default `3978`), both loopback-only by default (see
`linux-x86_64-vps/docker-compose.yml`). These are two independent
per-platform listeners, not a shared generic one — Hermes's other
`WEBHOOK_PORT=8644` feature (custom GitHub/GitLab/Supabase-style triggers)
is unrelated and not covered by this doc.

This page covers exposing both through one
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
(one connector, two public hostnames), so nothing on this VPS accepts a
direct inbound connection from the public internet at all — only
Cloudflare's edge does, relaying over an outbound-initiated tunnel.

Skip this page entirely if you only use Telegram.

## Prerequisites

- A Cloudflare account (free tier is enough — no paid plan required for a
  tunnel).
- A domain added to Cloudflare (Cloudflare Tunnel's public-hostname routing
  requires a zone Cloudflare manages — a free Cloudflare-registered or
  Cloudflare-proxied domain works; a "quick tunnel" with no domain also
  exists but issues a random, unstable hostname each restart, unsuitable
  for a webhook URL you register with Meta/Microsoft once).

## 1. Create the tunnel

1. Open the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/) → **Networks → Tunnels**.
2. **Create a tunnel** → choose **Cloudflared** as the connector.
3. Name it (e.g. `hermes-webhooks`).
4. On the **Install and run connector** step, choose **Docker** — Cloudflare
   generates a one-line `docker run` command containing a **tunnel token**.
   Copy just the token (the long string after `--token`) — this repo already
   has the `cloudflared` service wired up in `docker-compose.yml`, you don't
   need Cloudflare's generated command itself.
5. Paste the token into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.

## 2. Route a public hostname to each webhook listener

Still in the tunnel's configuration (**Public Hostname** tab), add **two**
entries — one per channel, each pointing at its own port:

| # | Subdomain (example) | Service | URL |
|---|---|---|---|
| 1 | `hermes-wa` | HTTP | `hermes:8090` (WhatsApp Cloud API) |
| 2 | `hermes-teams` | HTTP | `hermes:3978` (Microsoft Teams) |

`hermes` is the service name from `docker-compose.yml`, resolved over the
internal Docker network (`cloudflared` and `hermes` share the same Compose
network, so this works without either port being public). Use whatever
subdomains you like — they only need to be distinct from each other.

The two resulting URLs (e.g. `https://hermes-wa.yourdomain.com`,
`https://hermes-teams.yourdomain.com`) are what you give Meta and
Microsoft respectively as each platform's webhook endpoint — see
`shared/whatsapp-setup.md` / `shared/teams-setup.md` for exactly where
each asks for it, and note Teams' own requirement: it terminates TLS at
the tunnel and expects plain HTTP forwarded to `3978` — don't configure
the local service as HTTPS.

## 3. Start it

```bash
docker compose up -d cloudflared
docker compose logs -f cloudflared
```

Look for a line confirming registered connections (four, by default —
Cloudflare's connector maintains several for redundancy).

**If `CLOUDFLARE_TUNNEL_TOKEN` is left empty**, this container crash-loops
(`restart: unless-stopped` keeps retrying) rather than silently doing
nothing — expected until you complete step 1, not a bug to chase.

## Verify

```bash
curl https://hermes-wa.yourdomain.com/       # expect a response from the WhatsApp adapter, not a 502/523
curl https://hermes-teams.yourdomain.com/    # same, for the Teams adapter
```

Each should reach Hermes the same way `curl http://127.0.0.1:8090/` /
`:3978/` does locally on the VPS — confirms the whole path (Cloudflare
edge → tunnel → `cloudflared` container → the right `hermes` container
port) before registering either URL with Meta or Microsoft, so a setup
mistake surfaces here rather than as a mysterious "webhook verification
failed" on their side. Neither adapter necessarily answers `/health` —
check each platform's own doc for a real verification endpoint/handshake.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `cloudflared` keeps restarting | `CLOUDFLARE_TUNNEL_TOKEN` empty or wrong — re-copy it from the tunnel's Docker install step, not the tunnel's ID/name |
| One hostname returns 502/523, the other works | That hostname's **Service** URL must match its port exactly — `hermes:8090` for WhatsApp, `hermes:3978` for Teams; a swapped or typo'd port means Cloudflare's edge has nothing to relay to |
| Teams logs show `"UNKNOWN / HTTP/1.0" 400` | The tunnel is forwarding HTTPS instead of plain HTTP to `3978` — Teams' own doc is explicit that the local listener is HTTP-only, TLS terminates at Cloudflare |
| Works via `curl` but Meta/Microsoft still can't verify the webhook | Each platform independently verifies the endpoint (a challenge/response or signature check) — that's a `shared/whatsapp-setup.md` / `shared/teams-setup.md` concern, not this tunnel |

## Sources

- Cloudflare Tunnel, Docker connector, public hostname routing: [developers.cloudflare.com/cloudflare-one/connections/connect-networks](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- Hermes's webhook listener and `WEBHOOK_PORT`: [hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks)
