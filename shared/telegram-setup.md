# Telegram setup

Common to both configurations (macOS and Linux VPS): Hermes only talks to
Telegram once a bot has been created and its credentials filled into `.env`.
Every step below was walked through for real (including the mistakes) while
building this repo — the troubleshooting section reflects what actually went
wrong, not a guess at what might.

## 1. Create the bot with @BotFather

1. Open Telegram, search for **@BotFather**, send `/newbot`.
2. Give it a display name, then a username ending in `bot`
   (e.g. `my-hermes-bot`).
3. BotFather replies with a token that looks like:
   `123456789:ABCdefGHIjklMNOpqrSTUvwxYZ`
   → this is the value for `TELEGRAM_BOT_TOKEN`.

**Don't confuse the bot's own name/username with anything else below** —
easy mistake: the bot's display name and `@username` identify the *bot*,
never put them in `TELEGRAM_ALLOWED_USERS` (step 2 needs *your own* numeric
ID, a completely different number).

If you can't find the bot afterward by searching `@your_bot_username` in
Telegram (search indexing can lag right after creation, and a typo'd
username — `Hemes` vs `Hermes` — silently finds nothing rather than erroring):

- Use the direct link instead: `https://t.me/<username>` (no `@`).
- Or confirm the bot's real, exact username straight from the source:
  ```bash
  curl -s "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getMe"
  # {"ok":true,"result":{"id":...,"username":"Your_Real_Username", ...}}
  ```

## 2. Get your Telegram user ID

1. Search for **@userinfobot** on Telegram, send it any message.
2. It replies with a numeric `Id` → this is the value for
   `TELEGRAM_ALLOWED_USERS`.
3. Without this allow-list, anyone who finds the bot can message it.

## 3. Fill in `.env`

```bash
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
TELEGRAM_ALLOWED_USERS=123456789
```

Useful optional variables (see the official docs):

```bash
# Channel where Hermes delivers cron job results and proactive messages
TELEGRAM_HOME_CHANNEL=-1001234567890
TELEGRAM_HOME_CHANNEL_NAME="My assistant"

# For a group instead of a private chat
TELEGRAM_GROUP_ALLOWED_USERS=987654321
TELEGRAM_GROUP_ALLOWED_CHATS=-1001234567890
```

## 4. Apply the credentials

**Which command actually applies a `.env` change depends on whether the
container already exists.** This tripped us up live: `docker compose exec
hermes hermes gateway restart` restarts the gateway *process inside the
already-running container* — it does **not** re-read `.env`, because Docker
fixes a container's environment at creation time. Editing `.env` and running
only `hermes gateway restart` silently keeps using the *old* token.

- **First time, or after editing `.env`** (this is what actually reads the
  new values):
  ```bash
  docker compose up -d --force-recreate hermes
  ```
  (plain `docker compose up -d` also works and is usually enough — it
  detects the config changed and recreates the container on its own;
  `--force-recreate` just removes any doubt.)

- **Only if `.env` already had the right values and you just want to kick
  the gateway** (no `.env` edit involved): the interactive wizard or the
  in-container restart both work:
  ```bash
  docker compose exec hermes hermes gateway setup   # first-time interactive wizard
  # or
  docker compose exec hermes hermes gateway restart
  ```

## 5. Verify — and don't trust a stale status

```bash
docker compose logs --since 1m hermes | grep -i telegram
```

Look for `Connected to Telegram (polling mode)`. **Prefer this over `hermes
gateway status`** for a just-applied fix: `gateway status` reported a cached
`Telegram bot token rejected` error for us for several minutes *after* the
token was already corrected and the container recreated — the fresh
container logs showed `Connected` the whole time. If in doubt, the logs are
the source of truth, not the status summary.

Once connected:

1. Open the chat with the bot on Telegram (see the direct-link tip in step 1
   if search won't find it), tap `/start` (this just opens the chat, it
   isn't a real command), then send a message, e.g. "can you hear me?".
2. If Hermes replies "No home channel set for Telegram", send the
   `/set home` command so this channel also receives proactive notifications
   (cron jobs, background tasks).

### Why the first reply can take a very long time — and how to tell it's not stuck

Every message sends Hermes's **entire** system prompt, skill index, and tool
schemas, not just what you typed. Check your own deployment's real size:

```bash
docker exec hermes hermes prompt-size
```

On a stock deployment with the bundled skills from this repo, that's
already in the 40-50 KB range (roughly 12,000-15,000 tokens) before your
message is even added — and it only grows as Hermes learns more skills. On
a CPU-only VPS (no GPU), prompt processing measured around 6-7 tokens/second
in this repo's own testing (a KVM2, 2 vCPU instance) — so the *first* reply
in a session can genuinely take **25-40+ minutes**, not seconds, purely to
finish reading the prompt before generating a single word. This is not a
hang. Confirm it's actually working rather than stuck:

```bash
# on the VPS
docker exec llama-swap sh -c 'ps aux | grep llama-server'
# a high CPU% (e.g. 190%+ on a 2-vCPU box) and a growing TIME column means
# it's actively processing, not frozen
```

On the Mac (Metal-accelerated), the same prompt processes in seconds, not
minutes — if interactive latency matters to you, that's the practical
argument for the native macOS path over a small CPU-only VPS, independent
of Hermes itself. See
[`model-notes.md`](model-notes.md) and
[`prebuilt-binaries.md`](prebuilt-binaries.md) for the hardware trade-offs
this repo makes.

**This 25-40 minutes can exceed Hermes's own stream timeout, and then the
request fails outright instead of just being slow.** Hermes detects a local
endpoint and raises its stream-stale-timeout ceiling to 900 seconds (from a
180s base) — but that ceiling is still a hard cutoff, and a slow CPU-only
prefill can genuinely take longer than 900s to produce its first token. When
that happens, the logs show `Stream drop on attempt N/3 — retrying` with
`bytes=0 chunks=0` (confirmed in this repo's own VPS testing, 2026-09-03),
and after 3 failed attempts the request is dropped entirely. Both VPS config
templates in this repo (`linux-x86_64-vps/config/config.yaml.example` and
`scripts/setup-hermes-native.sh`) already set `agent.local_stream_stale_timeout:
3600` to cover this; if you're not using one of those, add it to
`config.yaml` yourself (or set the `HERMES_LOCAL_STREAM_STALE_TIMEOUT` env
var), sized above your own measured prefill time (`hermes prompt-size`
divided by your model's measured tokens/second).

### Hermes calling out to OpenRouter/Nous even though you never configured them

Confirmed live in this repo's own VPS testing, 2026-09-03: the logs showed
`Auxiliary: marking openrouter unhealthy (payment / credit error)` and the
same for `nous`, followed by `Title generation failed: Request timed out`
— all for a plain conversation, no explicit request to use another
provider. Hermes's default auxiliary-model routing (used for
session-title generation, image/vision analysis, and context compression)
tries free-tier external providers first, which:

- contradicts this repo's "nothing leaves the server" premise — an
  outbound network call is attempted regardless of whether it has
  credentials to succeed, and
- on a CPU-only VPS, contends for the same scarce CPU the main model is
  already using, adding latency to the response you're actually waiting
  on.

Both VPS config templates in this repo set
`auxiliary.title_generation.enabled: false` to stop it (session titles
still work manually via `/title`). Title generation is the only auxiliary
task Hermes runs unprompted — compression and vision only fire when
actually needed — so this one setting covers it for a Telegram-only text
deployment like this one.

## Troubleshooting

| Symptom | What actually happened (or what to check) |
|---|---|
| Can't find the bot when searching Telegram | Search indexing lag, or a typo'd username — use `https://t.me/<username>` directly, or confirm the real username with `curl https://api.telegram.org/bot<TOKEN>/getMe` |
| `TELEGRAM_ALLOWED_USERS` doesn't work / bot ignores you | You put the bot's own name/username there instead of *your* numeric ID from @userinfobot (step 2) — these are two different values |
| Changed `.env`, still get "token rejected" | You restarted the gateway *inside* the container instead of recreating it — run `docker compose up -d --force-recreate hermes` |
| `hermes gateway status` still shows an old error after fixing it | Status can be stale for several minutes — check `docker compose logs --since 1m hermes \| grep -i telegram` instead |
| Bot looks unresponsive for a long time on a VPS | Probably not stuck — see "Why the first reply can take a very long time" above; confirm with `ps aux \| grep llama-server` on the model-serving side |
| "No home channel set for Telegram" | Expected on first contact — reply with `/set home` |

Source: official Hermes Agent documentation —
[hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
(Telegram environment variables detailed in
[`telegram.md`](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/messaging/telegram.md)
in the official repository); the rest of this page reflects this repo's own
live testing, 2026-09-03.
