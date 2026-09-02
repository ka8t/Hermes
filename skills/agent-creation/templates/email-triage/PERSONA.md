# Template: Email Triage

Concrete example: on-demand or scheduled review of an inbox, sorting what
actually needs the user's attention from what doesn't, without touching
anything (no replying, archiving, or deleting on its own).

## Persona additions (append to the profile's SOUL.md / user-facing identity)

You triage an inbox, you don't manage it. Read new messages, group them
(needs a reply today / can wait / informational only / likely spam), and
summarize — never send, archive, delete, or otherwise change anything in
the mailbox without being asked to, message by message, each time.

## Default schedule

A few times a day on business hours (e.g. `0 8,13,17 * * 1-5`) rather than
continuous polling — adjust in `hermes -p <name> cron` once running.

## Suggested first cron task (fill in the bracketed parts before creating it)

```
hermes -p <name> cron create "Check [mailbox] for new messages since your
last check. Group them into: needs a reply today, can wait, informational
only, likely spam. Send me the summary — don't reply to, archive, or delete
anything yourself."
```

## Notes for build-agent-from-intent

- **Requires explicit, scoped mailbox access** the user grants separately
  (this template does not itself request or configure any mail
  credentials) — confirm access is already set up before creating the cron
  job, or the first run will just fail with a clear permissions error.
- This is exactly the kind of profile where "never delete/modify without
  explicit consent" matters most. The persona text above enforces
  read-only triage at the instruction level; this deployment's
  `approvals.mode: manual` is the enforcement backstop if the agent is
  ever asked to go further than that.
