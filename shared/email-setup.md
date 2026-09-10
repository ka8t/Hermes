# Email setup

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

**Status: configured, NOT live-verified.** hermes-agent's built-in `email`
platform (stdlib `smtplib`/`imaplib`, no extra dependencies — confirmed via
`install_hint` in the platform registry, `gateway/platform_registry.py`) is
now wired into this repo's `.env.example` on both platforms, and the
Telegram-only gateway-setup patch ([issue #90](https://github.com/ka8t/Hermes/issues/90))
allows it. **Not yet tested against a real mailbox** — do not treat this as
confirmed working until [issue #89](https://github.com/ka8t/Hermes/issues/89)
closes with a real send/receive round-trip.

## 1. Get a mailbox and an app password

Email is different from Telegram/WhatsApp/Teams here: there's no bot to
create — you point hermes-agent at a real mailbox it polls (IMAP) and
sends from (SMTP). A dedicated mailbox for the agent, not your personal
one, is strongly recommended — the password lives in plaintext in `.env`
(same tradeoff this repo already accepts for `TELEGRAM_BOT_TOKEN`).

**Gmail** (most common choice):
1. Enable 2-Step Verification on the account (required for the next step).
2. Create an **App Password**: Google Account → Security → 2-Step
   Verification → App passwords. Use this, not the account's real
   password — Gmail blocks plain-password IMAP/SMTP login for
   third-party apps.
3. IMAP/SMTP host/port are the standard Gmail values below; no other
   Gmail-side configuration needed.

Any other IMAP/SMTP provider works the same way in principle (get the
provider's IMAP/SMTP hostnames and an app-specific password if it offers
one) — only Gmail's exact steps are written out here since it's the most
common case; not verified against any other provider.

## 2. Fill in `.env`

```bash
EMAIL_ADDRESS=your-agent@gmail.com
EMAIL_PASSWORD=xxxx xxxx xxxx xxxx        # the App Password from step 1, not your real password
EMAIL_IMAP_HOST=imap.gmail.com
EMAIL_IMAP_PORT=993                        # default; TLS implicit on this port
EMAIL_SMTP_HOST=smtp.gmail.com
EMAIL_SMTP_PORT=587                        # default; STARTTLS on this port
EMAIL_ALLOWED_USERS=you@example.com        # comma-separated sender addresses allowed to message the agent
EMAIL_POLL_INTERVAL=15                     # seconds between mailbox checks
```

All defaults and variable names read directly from the adapter's own
source (`plugins/platforms/email/adapter.py`'s module docstring, read via
`docker exec hermes cat ...` against a running container, 2026-09-10) —
not assumed. `EMAIL_IMAP_SECURITY`/`EMAIL_SMTP_SECURITY` (`tls` |
`starttls` | `plain`, left unset here since the ports above already imply
the right default) and `EMAIL_IMAP_TLS_VERIFY`/`EMAIL_SMTP_TLS_VERIFY`
(default `true`) are also available if a provider needs a non-default
transport.

**`EMAIL_ALLOWED_USERS` matters more here than on Telegram**: an
inbound-email agent with no allow-list would act on mail from anyone who
learns its address (spam, phishing) — unlike Telegram, where
`TELEGRAM_ALLOWED_USERS` gates by numeric user ID that's harder to guess
or spoof. Don't leave this empty on a real deployment.

## 3. Apply the credentials

Same mechanism as Telegram (see
[`telegram-setup.md`](telegram-setup.md)'s "Apply the credentials"
section, and [`single-env-file.md`](single-env-file.md) for why): Docker
fixes a container's environment variables at creation time, so a `.env`
edit needs `docker compose up -d` (recreate, not just `restart`) before
hermes-agent's process actually sees the new values.

## 4. Verify

**Not yet done — see [issue #89](https://github.com/ka8t/Hermes/issues/89).**
Planned verification, once a real test mailbox is available:
- `docker compose logs hermes` shows a successful IMAP connection (no
  auth error) shortly after recreate.
- Send a real email from an `EMAIL_ALLOWED_USERS` address to
  `EMAIL_ADDRESS`, confirm a reply arrives within `EMAIL_POLL_INTERVAL` +
  normal inference time.
- Confirm a message the agent initiates (e.g. a `hermes cron` report)
  actually lands in the recipient's inbox, not just spam — Gmail/other
  providers can flag mail from a fresh app-password sender.

## Troubleshooting

Not yet populated — no real deployment has hit a failure mode to
document yet. Expect this section to fill in once #89's live test runs.

## Sources

- `plugins/platforms/email/adapter.py`'s module docstring and
  `gateway/platform_registry.py`'s registered entry for `email` — read
  directly from the running `ghcr.io/ka8t/hermes:latest` container via
  `docker exec`, 2026-09-10, not assumed from upstream documentation
  (hermes-agent's own docs for this platform weren't checked separately;
  the source is the primary source here).
- Gmail App Passwords: standard Google Account documentation (2-Step
  Verification is a prerequisite for generating one) — not independently
  verified against a real account as part of this write-up.
