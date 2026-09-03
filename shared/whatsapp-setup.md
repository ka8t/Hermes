# WhatsApp Business Cloud API setup

Meta's official WhatsApp integration — no Node.js bridge, no QR code, no
account-ban risk (unlike the alternative Baileys bridge, which this repo
deliberately doesn't use — see
[`../docker/README.md`](../docker/README.md) and issue
[#16](https://github.com/ka8t/Hermes/issues/16) for why). In exchange, it
needs a Meta Business account and a public HTTPS URL Meta can deliver
messages to.

Not yet verified against a real Meta account by this repo — see
"Status" at the bottom before relying on this in production.

## 1. Create a Meta Business account and app

1. Create a Business account at [business.facebook.com](https://business.facebook.com/) if you don't have one.
2. Go to [developers.facebook.com/apps](https://developers.facebook.com/apps) → **Create App**.
3. Use case: **"Connect with customers through WhatsApp"** → **Next**.
4. Pick or create a business portfolio → **Create app**.
5. On **Connect on WhatsApp → Quickstart**, click **Start using the API** — you land on **API Setup**, where a WhatsApp Business Account (WABA) is auto-linked.

## 2. Collect the required values

From the App Dashboard's **WhatsApp → API Setup** and **Settings → Basic** pages:

| Value | Where | Goes into |
|---|---|---|
| Phone Number ID (15-17 digits — **not** the phone number itself) | API Setup, below the "From" dropdown | `WHATSAPP_CLOUD_PHONE_NUMBER_ID` |
| Access Token (starts `EAA`) | API Setup → "Generate access token" (temporary, 24h — see step 3 for a permanent one) | `WHATSAPP_CLOUD_ACCESS_TOKEN` |
| App Secret (32-char hex) | Settings → Basic → "Show" | `WHATSAPP_CLOUD_APP_SECRET` — **required**; without it, inbound delivery is refused with HTTP 503 |

## 3. Get a permanent access token (skip only for a throwaway test)

The temporary token from step 2 expires in 24 hours. For anything longer:

1. [business.facebook.com/latest/settings](https://business.facebook.com/latest/settings) → **System users** → **Add** (e.g. `hermes-bot`, role **Admin**).
2. Select it → **Assign Assets** → your app (**Manage app**, Full control) and your WhatsApp account (**Manage WhatsApp Business Accounts**, Full control) → **Assign assets**.
3. **Generate token** with `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management` → expiration **Never**.
4. Put this token in `WHATSAPP_CLOUD_ACCESS_TOKEN` instead of the temporary one.

## 4. Expose the webhook publicly

WhatsApp Cloud API delivers messages by POSTing to your webhook — Meta's
servers must be able to reach this VPS. This repo uses Cloudflare Tunnel
for this — see
[`cloudflare-tunnel-setup.md`](cloudflare-tunnel-setup.md) and set it up
before continuing (route a public hostname to `hermes:8090`, matching
`WHATSAPP_CLOUD_WEBHOOK_PORT`'s default in `.env.example`).

## 5. Generate a verify token and fill in `.env`

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Put the result in `WHATSAPP_CLOUD_VERIFY_TOKEN`. Fill in the rest of the
`WHATSAPP_CLOUD_*` block in `.env` from steps 2-3, then add your own
WhatsApp number (the `wa_id` — country code + number, no `+` or spaces,
e.g. `15551234567`) to `WHATSAPP_CLOUD_ALLOWED_USERS`. Restart:

```bash
docker compose up -d --force-recreate hermes
```

## 6. Configure the webhook on Meta's side

App Dashboard → **WhatsApp → Configuration** → edit the Webhook section:

- **Callback URL**: your Cloudflare Tunnel hostname from step 4 +
  `/whatsapp/webhook` (Hermes's default `WHATSAPP_CLOUD_WEBHOOK_PATH`) —
  e.g. `https://hermes-wa.yourdomain.com/whatsapp/webhook`.
- **Verify Token**: the value from step 5, exactly.

Meta calls this URL once to verify (a GET handshake) before accepting it —
if verification fails, re-check the verify token matches and that
`docker compose logs hermes` shows the gateway already running.

## Status

Implemented (config templates, `.env.example`, this doc) but **not yet
verified against a real Meta Business account and a real message
round-trip** — that requires account creation and phone verification only
the deploying user can do. Treat every step above as "should work per
Meta's and Hermes's own documentation," not "confirmed working," until
someone completes it end-to-end and this note is updated.

## Sources

- Official Hermes WhatsApp Cloud API guide: [hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp-cloud](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp-cloud)
- Meta for Developers — WhatsApp Cloud API: [developers.facebook.com/docs/whatsapp/cloud-api](https://developers.facebook.com/docs/whatsapp/cloud-api)
