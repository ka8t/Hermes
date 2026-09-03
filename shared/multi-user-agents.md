# Multi-user agent isolation

By default, this repo's stack serves **one** Telegram allow-list
(`TELEGRAM_ALLOWED_USERS`) into **one** Hermes profile — every allowed
person shares the same memory, the same cron jobs, the same "agents"
created via [`skills/agent-creation/`](../skills/agent-creation/). That's
fine for a single user. It stops being fine the moment a second person is
allowed in: nothing would scope who can see or manage which agent.

Tracked as [issue #5](https://github.com/ka8t/Hermes/issues/5) and its
sub-issues (#6-#9).

## The model: one Hermes profile per user

Each end-user gets their **own Hermes profile** — a separate home directory
with its own memory, skills, and (this is the part that matters) its own
`~/.hermes/profiles/<name>/cron/jobs.json`. One shared bot token still
serves everyone: `gateway.multiplex_profiles: true` plus a
`gateway.profile_routes` entry per user routes their `platform`+`chat_id` to
their own profile (in a Telegram DM, `chat_id` equals the sender's numeric
`user_id`, so this routes per-person, not just per-server). Traffic that
matches no route keeps using the default profile, so an unrouted deployment
behaves exactly as before.

Isolation is then structural, not a filter applied after the fact: a user's
`/cron list` inside their own profile physically cannot return anyone
else's jobs, because no one else's jobs exist in that profile's
`jobs.json`.

## What was considered and rejected

**Filtering a single shared cron table by an inferred "owner".** Hermes's
own docs describe that table as flat and explicitly un-owned — filtering it
after the fact would be a soft, model-adjacent safeguard (something an LLM
is instructed to respect, not something enforced), not a real boundary.
Rejected for the same reason [`enterprise-safety.md`](enterprise-safety.md)
is explicit about what Hermes's approval system does and doesn't cover:
don't claim an isolation guarantee this architecture can't actually back up.

**An in-chat admin-vs-regular-user command split.** Hermes has
`allow_admin_from` / `user_allowed_commands` per platform, which was the
initial idea. Dropped once profile-per-user was settled: each profile
belongs to exactly one person, so there is no "other regular user" to
restrict commands from *inside* their own profile. The commands that
actually need protecting — creating a profile, adding a route, restarting
the gateway — are fleet-management actions that happen over SSH/CLI on the
admin's own machine, never as a chat command in any user-facing profile.

## Onboarding a new user

**Manual (recommended for a small team):**

```bash
cd linux-x86_64-vps
./scripts/build-agent-template.sh                       # once, or after updating this repo's config/skills
./scripts/provision-user.sh telegram <their_user_id> <slug>
```

`provision-user.sh` clones the `agent-template` profile, adds the route, and
restarts the gateway — only if something actually changed (idempotent; a
`chat_id` already routed to a *different* profile is refused, not
overwritten). See the "Scripts reference" section of
[`../linux-x86_64-vps/README.md`](../linux-x86_64-vps/README.md) for exact
parameters.

**Automated, for higher volumes:** a companion script/timer can watch for
users who are approved (`hermes pairing approve` / added to
`TELEGRAM_ALLOWED_USERS`) but not yet provisioned, and run
`provision-user.sh` for them automatically — see
[issue #8](https://github.com/ka8t/Hermes/issues/8) for the current status.
**The human approval decision itself always stays manual** — automation only
removes the mechanical follow-through step after that decision, never the
decision.

## What this does NOT do

Deciding **who is allowed to talk to the bot at all** is unrelated to
everything above — that's `TELEGRAM_ALLOWED_USERS` (or `hermes pairing
approve` for the pairing-code flow), a human decision made before
`provision-user.sh` ever runs. This page is entirely about what happens
*after* someone is already allowed in: which agents they can see and
manage.

This is currently **Docker-only, on the VPS configuration**
([`linux-x86_64-vps/`](../linux-x86_64-vps/)). The macOS configuration and
both platforms' native (no-Docker) paths don't yet have an equivalent —
see each platform's README, "Scripts reference".

`provision-user.sh` isn't restricted to Telegram — `gateway.profile_routes`
routes any platform Hermes's gateway supports. WhatsApp and Microsoft
Teams (see [`whatsapp-setup.md`](whatsapp-setup.md) /
[`teams-setup.md`](teams-setup.md), tracked in
[issue #16](https://github.com/ka8t/Hermes/issues/16)) work the same way
once configured — see the script's own header comment for what each
platform's `<chat_id>` argument should be. Neither channel has been
verified against a real account yet, so treat the multi-user path for
them as unverified too until [issue #20](https://github.com/ka8t/Hermes/issues/20)
confirms it end-to-end.

## Sources

- Profiles, `hermes profile create`, `--clone-from`: [hermes-agent.nousresearch.com/docs/user-guide/profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles)
- Multiplexed gateways, `gateway.profile_routes`: [hermes-agent.nousresearch.com/docs/user-guide/multi-profile-gateways](https://hermes-agent.nousresearch.com/docs/user-guide/multi-profile-gateways)
- Cron jobs' flat, unowned table: [hermes-agent.nousresearch.com/docs/user-guide/features/cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)
- Per-platform admin/user slash-command split (`allow_admin_from`): [hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram) — considered, not used; see above.
