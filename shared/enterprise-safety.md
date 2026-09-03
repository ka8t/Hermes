# Enterprise safety: approvals and consent

Both reference configurations, and the packaged `ghcr.io/ka8t/hermes` image
(see [`../docker/`](../docker/)), ship with one deliberate override on top
of Hermes's own defaults:

```yaml
approvals:
  mode: manual
```

## What this actually does (verified against the official docs)

Hermes already checks every terminal command against a curated list of
dangerous patterns (`rm -rf`, `DROP TABLE`, and similar) before running it.
`approvals.mode` controls what happens on a match:

| Mode | Behavior |
|---|---|
| `smart` (Hermes's own default) | An auxiliary LLM judges risk; low-risk commands are auto-approved, only uncertain/dangerous ones escalate to a human |
| **`manual` (what this repo sets)** | **Every** flagged dangerous action always asks a human — no auto-approval, ever |
| `off` | No approval checks at all (equivalent to `--yolo`) |

This is why `manual`, not a deny-list, is the right lever for "no file
deletion without explicit consent": the request was for *consent*, not a
permanent ban — `mode: manual` guarantees a human is asked every time,
while still allowing the action once they say yes.

Three related settings already default to the safe choice and don't need
overriding:

- `cron_mode: deny` — a scheduled job that hits a dangerous command is
  blocked outright (there's no human present to ask).
- `single_query_mode: deny` — same, for **`hermes chat -q`** sessions.
- `unattended_mode: deny` — same, for webhook/API-triggered sessions.

So in every context where nobody could actually grant consent, Hermes
already refuses by default; `mode: manual` closes the remaining gap, which
was interactive/gateway sessions with a human present but `smart` mode
willing to auto-approve on their behalf.

### `hermes -z`/`--oneshot` is NOT covered by any of this — corrected 2026-09-03

**This section previously stated that `single_query_mode: deny` covers
`hermes -z` sessions "same" as `hermes chat -q`. That was wrong — verified
empirically (issue [#38](https://github.com/ka8t/Hermes/issues/38)) and
confirmed directly against the installed CLI's own `--help` text, not
assumed:**

```
-z, --oneshot PROMPT  One-shot mode: send a single prompt and print ONLY the
                       final response text to stdout. [...] Tools, memory,
                       rules, and AGENTS.md in the CWD are loaded as normal;
                       approvals are auto-bypassed. Intended for scripts / pipes.
```

`-z`/`--oneshot` and `hermes chat -q` are two different commands with
**opposite** default approval behavior:

| Command | Governed by | Default behavior on a dangerous command |
|---|---|---|
| `hermes chat -q` | `single_query_mode` | `deny` — blocked outright, no human to ask |
| `hermes -z` / `--oneshot` | nothing — hardcoded | **always auto-bypassed**, unconditionally |

This is not a bug and not something `approvals.mode`, `single_query_mode`,
or this repo's `manual` override can change — `-z` bypasses **every**
dangerous-command check by design, the same as running with `--yolo`,
regardless of config. Confirmed live: a `rm -r` on a test path (a pattern
explicitly listed in the "What Triggers Approval" table above) executed
immediately through the `terminal` tool in a `hermes -z` session, with no
approval step anywhere in the recorded tool-call trace (`state.db`,
session `20260903_114926_821b3a`) — it only failed to actually delete the
target because that target happened to be owned by a different user, an
unrelated filesystem permission, not an approval decision.

**Practical consequence**: never use `hermes -z` for anything that could
touch destructive commands unattended (a cron-like automation, a script
an admin points at real data) — use `hermes chat -q` instead if
unattended headless execution needs the `deny` protection. `-z` is only
appropriate for read-only or already-trusted one-off queries. Nothing in
this repo's own scripts or skills invokes `-z` in production today
(verified by search); this note exists so a future admin reaching for
`-z` for "a quick script" — exactly the use case the CLI's own help text
invites — doesn't assume it's protected.

## What this does NOT do

**Hermes has no mechanism to route approval to someone other than the
person who triggered the action** — verified against the official security
docs, not assumed. There is no delegated-approver model, no group-based
sign-off, and no SSO/OAuth-gated approval flow. "The user must explicitly
approve it" always means *that* user, in *that* session.

If your organization needs a **different person or group** — say, an admin
team, gated by your company's SSO — to approve destructive actions taken by
an agent someone else is chatting with, that is not covered by
`approvals.mode` and does not exist in this repo today. It would require a
custom approval-routing layer sitting in front of Hermes's tool calls (e.g.
a proxy that intercepts destructive requests and requires a separate,
authenticated sign-off before letting them through). This is tracked as
future work, not silently assumed to work — see
[issue #4](https://github.com/ka8t/Hermes/issues/4) for the current status
before relying on it in a multi-user deployment.

## Where this is set

- [`macos-arm64/config/config.yaml.example`](../macos-arm64/config/config.yaml.example)
- [`linux-x86_64-vps/config/config.yaml.example`](../linux-x86_64-vps/config/config.yaml.example)
- [`docker/Dockerfile`](../docker/Dockerfile) (appended to the base image's
  own reference config, applied on first boot only — see the Dockerfile's
  comments)

It's a normal `config.yaml` key, so it can be changed like any other
setting after the fact (`hermes config set approvals.mode smart`, or edit
the file directly) — this is a shipped default, not a lock.

## Sources

- Approval system, modes, and their exact defaults: [hermes-agent.nousresearch.com/docs/user-guide/security](https://hermes-agent.nousresearch.com/docs/user-guide/security/) (fetched and read directly, not summarized, given how much the exact defaults matter here)
