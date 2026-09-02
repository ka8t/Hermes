# Telegram setup

Common to both configurations (macOS and Linux VPS): Hermes only talks to
Telegram once a bot has been created and its credentials filled into `.env`.

## 1. Create the bot with @BotFather

1. Open Telegram, search for **@BotFather**, send `/newbot`.
2. Give it a display name, then a username ending in `bot`
   (e.g. `my-hermes-bot`).
3. BotFather replies with a token that looks like:
   `123456789:ABCdefGHIjklMNOpqrSTUvwxYZ`
   → this is the value for `TELEGRAM_BOT_TOKEN`.

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

## 4. Enable the channel on the Hermes side

Once the container is running (see each platform's README), run the
interactive wizard once:

```bash
docker compose exec hermes hermes gateway setup
# -> pick "Telegram"
# -> confirm the token is correctly read from .env
```

Or, if the agent is already running and `.env` already has the right values,
a simple gateway restart is enough:

```bash
docker compose exec hermes hermes gateway restart
docker compose exec hermes hermes gateway status
```

## 5. Verify

1. Open the chat with the bot on Telegram, tap `/start` (this just opens the
   chat, it isn't a real command), then send a message, e.g. "can you hear
   me?".
2. If Hermes replies "No home channel set for Telegram", send the
   `/set home` command so this channel also receives proactive notifications
   (cron jobs, background tasks).

Source: official Hermes Agent documentation —
[hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
(Telegram environment variables detailed in
[`telegram.md`](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/messaging/telegram.md)
in the official repository).
