# WhatsApp Business Cloud API setup

Meta's official WhatsApp integration — no Node.js bridge, no QR code, no
account-ban risk (unlike the alternative Baileys bridge, which this repo
deliberately doesn't use — see issue
[#16](https://github.com/ka8t/Hermes/issues/16) for why). In exchange, it
needs a Meta Business account and a public HTTPS URL Meta can deliver
messages to.

Not yet verified against a real Meta account by this repo — see
"Status" at the bottom before relying on this in production.

## 1. Create a Meta Business account and app

1. Create a Business account at [business.facebook.com](https://business.facebook.com/) if you don't have one.
2. Go to [developers.facebook.com/apps](https://developers.facebook.com/apps) → **Create App**.
3. Use case: **"Connect with customers through WhatsApp"** → **Next**.
4. Pick or create a business portfolio. Review the publishing requirements → **Create app**.
5. On **Connect on WhatsApp → Quickstart**, click **Start using the API** — you land on **API Setup**, where a WhatsApp Business Account (WABA) is auto-linked (auto-created if you made a new portfolio in step 4).

## 2. Collect the required values

From the App Dashboard's **WhatsApp → API Setup** and **Settings → Basic** pages:

| Value | Where | Field shape | Goes into |
|---|---|---|---|
| Phone Number ID | API Setup, below the "From" dropdown | Numeric, 15-17 digits | `WHATSAPP_CLOUD_PHONE_NUMBER_ID` — **not** the phone number itself; this is the #1 setup mistake per the official docs |
| Access Token | API Setup → "Generate access token" | Starts `EAA`, 100+ chars | `WHATSAPP_CLOUD_ACCESS_TOKEN` — temporary, 24h; see step 3 for a permanent one |
| App Secret | Settings → Basic → "Show" next to App secret | 32-char lowercase hex | `WHATSAPP_CLOUD_APP_SECRET` — **required**; without it, inbound delivery is refused with HTTP 503 |
| App ID (optional) | Settings → Basic | Numeric, 15-16 digits | `WHATSAPP_CLOUD_APP_ID` — not required for messaging, useful for future analytics |
| WABA ID (optional) | API Setup, near the top | Numeric, 15+ digits | `WHATSAPP_CLOUD_WABA_ID` — same, analytics only |

## 3. Get a permanent access token (skip only for a throwaway test)

The temporary token from step 2 expires in 24 hours — a token generated
today stops working tomorrow. For anything longer-lived:

1. [business.facebook.com/latest/settings](https://business.facebook.com/latest/settings) → **System users** → **Add** (e.g. `hermes-bot`, role **Admin**).
2. Select it → **Assign Assets**: your app (toggle **Manage app** under Full control) and your WhatsApp account (toggle **Manage WhatsApp Business Accounts** under Full control) → **Assign assets**.
3. **Generate token** with all three permissions: `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management` → expiration **Never**.
4. Put this token in `WHATSAPP_CLOUD_ACCESS_TOKEN` instead of the temporary one.

System User tokens don't expire unless explicitly revoked.

## 4. Expose the webhook publicly

WhatsApp Cloud API delivers messages by POSTing to your webhook — Meta's
servers must be able to reach this VPS. This repo uses Cloudflare Tunnel
for this — see [`cloudflare-tunnel-setup.md`](cloudflare-tunnel-setup.md)
and set it up before continuing (route a public hostname to
`hermes:8090`, matching `WHATSAPP_CLOUD_WEBHOOK_PORT`'s default in
`.env.example`).

## 5. Generate a verify token and fill in `.env`

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Put the result in `WHATSAPP_CLOUD_VERIFY_TOKEN`. Fill in the rest of the
`WHATSAPP_CLOUD_*` block in `.env` from steps 2-3, then add your own
WhatsApp number — the `wa_id`, country code + number, no `+`/spaces/dashes,
e.g. `15551234567` — to `WHATSAPP_CLOUD_ALLOWED_USERS`. Restart:

```bash
docker compose up -d --force-recreate hermes
```

## 6. Configure the webhook on Meta's side

App Dashboard → **WhatsApp → Configuration** → edit the Webhook section:

1. **Callback URL**: your Cloudflare Tunnel hostname from step 4 +
   `/whatsapp/webhook` (Hermes's default `WHATSAPP_CLOUD_WEBHOOK_PATH`) —
   e.g. `https://hermes-wa.yourdomain.com/whatsapp/webhook`.
2. **Verify Token**: the value from step 5, exactly.
3. Click **Verify and save** — Meta sends a GET request with a challenge,
   the gateway echoes it back, and Meta marks the webhook verified.
4. Under **Webhook fields**, click **Manage** → subscribe to the
   **messages** field. Without this, Meta never actually delivers inbound
   messages, even with a verified webhook.

**Manual verification, before touching Meta's dashboard** (catches setup
mistakes locally rather than as a cryptic "URL couldn't be validated" in
Meta's UI):

```bash
TUNNEL="https://hermes-wa.yourdomain.com"
VERIFY="<your WHATSAPP_CLOUD_VERIFY_TOKEN>"

# Should print HTTP 200 with body "hello"
curl -i "$TUNNEL/whatsapp/webhook?hub.mode=subscribe&hub.verify_token=$VERIFY&hub.challenge=hello"

# Should show verify_token_configured: true and app_secret_configured: true
curl "$TUNNEL/health"
```

## 7. Recipient whitelist (Meta's side — dev mode)

Before your app passes Meta's App Review, it can only message numbers
you've explicitly added:

1. App Dashboard → WhatsApp → API Setup → **To** dropdown → **Manage phone number list**.
2. Add each number you want to message (yourself, your team, testers).
   Meta sends each a 6-digit verification code via SMS or WhatsApp.

**Up to 5 numbers in dev mode.** App Review removes this limit — out of
scope for this doc, see Meta's own App Review documentation.

## 8. The Hermes-side allowlist (separate from Meta's)

`WHATSAPP_CLOUD_ALLOWED_USERS` (set in step 5) controls which **inbound**
messages Hermes actually processes — independent of Meta's recipient
whitelist above, which controls who Meta lets you message at all.
**Without an allowlist, every inbound message is denied by default** —
intentional, so the bot can't be invoked by a random number if Meta's own
whitelist is ever loosened or removed (post-App-Review). Set
`WHATSAPP_CLOUD_ALLOW_ALL_USERS=true` only if you deliberately want anyone
Meta lets through to also reach the agent.

## Full configuration reference

All variables live in `.env`. Required ones are in **bold**.

| Variable | Default | Description |
|---|---|---|
| **`WHATSAPP_CLOUD_PHONE_NUMBER_ID`** | — | 15-17 digit ID from API Setup — not the phone number |
| **`WHATSAPP_CLOUD_ACCESS_TOKEN`** | — | Meta access token, temp (24h) or System User (permanent) |
| **`WHATSAPP_CLOUD_APP_SECRET`** | — | 32-char hex; without it inbound is refused with 503 |
| **`WHATSAPP_CLOUD_VERIFY_TOKEN`** | — | Shared secret for the GET handshake |
| **`WHATSAPP_CLOUD_ALLOWED_USERS`** | — | Comma-separated `wa_id`s allowed to message the bot |
| `WHATSAPP_CLOUD_ALLOW_ALL_USERS` | `false` | Bypass the Hermes-side allowlist |
| `WHATSAPP_CLOUD_APP_ID` | — | Optional, analytics only |
| `WHATSAPP_CLOUD_WABA_ID` | — | Optional, analytics only |
| `WHATSAPP_CLOUD_WEBHOOK_HOST` | unset (all interfaces) | Interface the webhook server binds to |
| `WHATSAPP_CLOUD_WEBHOOK_PORT` | `8090` | Must match the port the tunnel forwards — see `cloudflare-tunnel-setup.md` |
| `WHATSAPP_CLOUD_WEBHOOK_PATH` | `/whatsapp/webhook` | URL path Meta posts to |
| `WHATSAPP_CLOUD_API_VERSION` | `v20.0` | Meta Graph API version — only override per Meta's own migration guidance |
| `WHATSAPP_CLOUD_HOME_CHANNEL` | — | `wa_id` used as the bot's home channel for cron/proactive deliveries |

You can run **both** this adapter and the Baileys bridge (`whatsapp`)
simultaneously, targeting different phone numbers — not something this
repo configures by default, but supported upstream.

## What actually works over this channel

**Inbound**: text; images (vision-capable models read them directly,
others get an auto-generated text description); voice notes (transcribed
via the configured STT provider); documents (small text files up to 100KB
inlined directly, larger ones cached for tool access); button taps (routed
to the right handler — clarify choices, approval prompts); reply context
(the agent sees the original message when the user replies to one).

**Outbound**: text (markdown auto-converted to WhatsApp's syntax:
`**bold**` → `*bold*`, long messages split at 4096 chars); images; voice
messages (TTS output converted via `ffmpeg` into a native voice-note
bubble — install `ffmpeg` on the image/host or it falls back to a plain
MP3 attachment); video/documents.

**Interactive UX**: the `clarify` tool renders as tap-to-answer buttons
(1-3 choices) or a list sheet (4+), with a "✏️ Other" free-text option;
dangerous-command approvals show ✅/❌ buttons instead of requiring
`/approve`/`/deny` typed out; the bot shows blue double-checkmarks on
receipt and a "typing…" indicator while working. All of this degrades
gracefully to plain text on clients that can't render buttons.

## Known limitations (Meta's rules, not Hermes's)

- **24-hour conversation window**: free-form replies only work within 24h
  of the user's last message. Outside that window, Meta requires a
  pre-approved message **template** — not yet implemented in Hermes.
  Concretely: reactive chat works indefinitely; a cron job or a
  long-running `delegate_task` result delivered after a >24h gap fails
  with Graph error `131047`.
- **Groups**: this adapter is **direct-messages only** (v1). Use the
  Baileys bridge if you need WhatsApp group support.
- **Outbound rate limit**: Meta allows 80 msg/sec per business number by
  default; Hermes doesn't enforce this client-side.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Meta dashboard: "URL couldn't be validated" | Stale tunnel URL, verify-token mismatch, gateway not running, or `WHATSAPP_CLOUD_APP_SECRET` unset (which makes Hermes refuse with 503, which Meta reports as validation failure) — run the manual curl probe in step 6 first |
| `graph error 100`: "Object with ID '...' does not exist" | You put the phone number itself into `WHATSAPP_CLOUD_PHONE_NUMBER_ID` instead of Meta's internal Phone Number ID (shown below the "From" dropdown) |
| `graph error 190` subcode 463 | Access token expired (temp tokens last 24h) — regenerate or switch to a System User token |
| `graph error 190` subcode 467 | Token was revoked, or the account password changed |
| `graph error 190`, other subcode | Token was generated without all three required permissions |
| `graph error 131047`: "Re-engagement message" | The 24h window expired — see Known limitations |
| Bot replies as raw JSON / tool-call-shaped text | The toolset configured for `whatsapp_cloud` is effectively empty — check `hermes tools list` |
| STT (voice transcription) returns empty | Default `stt.provider: local` needs `pip install faster-whisper` inside the Hermes environment; a Nous subscription can route STT through the managed gateway instead (`hermes config set stt.provider nous`) |

## Security notes

- **App Secret = as sensitive as a password.** Anyone with it can forge
  webhook payloads Hermes will accept as authentic.
- **Access token = your bot's identity.** System User tokens are
  long-lived API keys — rotate immediately if a deployment is compromised.
- **The `/health` endpoint is unauthenticated** but only reports
  config-presence booleans, not values — safe to leave reachable, or
  restrict at the tunnel layer if you'd rather not expose even that.

## Comparison to the Baileys bridge (why this repo picked Cloud API)

| | Baileys (`whatsapp`) | Cloud API (this doc) |
|---|---|---|
| Account type | Personal | Business |
| Public URL needed | No | Yes |
| Account ban risk | Yes | No |
| Groups | Full support | DMs only |
| 24h window | No restriction | Hard rule, templates required after |
| Interactive buttons | Text fallback only | Native |
| Production use | Risky | Designed for it |

## Status

Implemented (`.env.example`, `docker-compose.yml`'s port mapping, this
doc) but **not yet verified against a real Meta Business account and a
real message round-trip** — that requires account creation and phone
verification only the deploying user can do. Treat every step above as
"should work per Meta's and Hermes's own documentation," not "confirmed
working," until someone completes it end-to-end and this note is updated.

## Sources

- Official Hermes WhatsApp Cloud API guide (steps, config reference, troubleshooting, all verified against this exact page): [hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp-cloud](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp-cloud)
- Meta for Developers — WhatsApp Cloud API (authoritative on pricing, App Review, Meta-side rate limits): [developers.facebook.com/docs/whatsapp/cloud-api](https://developers.facebook.com/docs/whatsapp/cloud-api)
