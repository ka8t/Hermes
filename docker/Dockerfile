# Ready-to-run Hermes Agent image: the upstream image, plus this repo's
# guided agent-creation skills, an enterprise-safe approval default, a
# fix for a real llama-server bug (#50), and a mandatory
# verify-before-success identity instruction (#48).
#
# What this does NOT bundle: a model, or llama-swap/llama-server — those
# stay separate services (see ../macos-arm64/ and ../linux-x86_64-vps/),
# because they need platform-specific handling (Metal on Mac, CPU on a
# generic VPS) that doesn't belong baked into one image. Point this
# container's config.yaml at whichever llama-swap endpoint you're running,
# exactly as documented for the vanilla image — this Dockerfile only adds
# skills and a safer default, it doesn't change how Hermes is configured.
#
# Build: docker build -f docker/Dockerfile -t ghcr.io/ka8t/hermes:latest .
# (build context must be the repo root, so COPY ../skills below resolves)
FROM nousresearch/hermes-agent:latest

# --- Bundled skills (see ../skills/agent-creation, ../skills/reliability) ---
# ../skills/reliability holds verify-before-success (#49) — discretionary,
# skill-indexed, found live-testing to be an insufficient fix on its own
# for #48's hallucinated-success failure (kept as a secondary nudge; see
# the always-injected SOUL.md fix below for the actual correction).
# Synced into every deployment's live skills directory automatically by the
# base image's own boot sequence (docker/stage2-hook.sh's skills_sync.py,
# confirmed by inspecting nousresearch/hermes-agent:latest) — nothing else
# needed here for the skills themselves to take effect.
COPY skills/agent-creation /opt/hermes/skills/ka8t-hermes/agent-creation
COPY skills/reliability /opt/hermes/skills/ka8t-hermes/reliability

# --- web_search schema fix (#50) ---
# llama-server has hardcoded, name-based special handling for any tool
# literally called "web_search": it validates the call against its own
# internal query-only contract regardless of what schema the client (us)
# actually declares for that name — confirmed directly via `strings` on
# the compiled llama-server binary (contains both the literal string
# "web_search" and the generic JSON-schema-validator error vocabulary
# right next to it), and via direct A/B testing against the live server
# (identical schema, different tool name: succeeds; "web_search" name,
# any second property: rejected, regardless of required/optional). An
# earlier attempt at this fix — making "limit" required instead of
# optional — did NOT work, because the collision is on the tool *name*,
# not on which properties are required; corrected here. Renaming the
# tool itself was considered and rejected: several of the base image's
# own bundled skills instruct the model to call "web_search" by that
# exact name, and renaming would silently break all of them. Removing
# "limit" from the schema entirely keeps the name and the default
# 5-result behavior, just without the model's ability to request a
# different count. See shared/model-notes.md and
# docker/patch-web-search-schema.py for the exact patch.
COPY docker/patch-web-search-schema.py /tmp/patch-web-search-schema.py
RUN python3 /tmp/patch-web-search-schema.py && rm /tmp/patch-web-search-schema.py

# --- Allowed-channels gateway setup menu ---
# `hermes gateway setup`'s platform picker (_all_platforms() in
# hermes_cli/gateway.py) lists every built-in and plugin-registered
# messaging platform upstream ships (Discord, WhatsApp, Signal, Matrix, IRC,
# Mattermost, Weixin, Slack...). This repo documents Telegram
# (shared/telegram-setup.md) and email (shared/email-setup.md, issue #89)
# end-to-end — offering the rest invites picking a channel that looks
# configured but was never verified on this stack. Was Telegram-only
# (#83) until a real user story needed email too (#90) — see
# docker/patch-gateway-setup-allowed-channels.py for the exact patch,
# its ALLOWED_KEYS policy, and why filtering the menu beats trying to
# grey out entries in upstream's curses picker.
COPY docker/patch-gateway-setup-allowed-channels.py /tmp/patch-gateway-setup-allowed-channels.py
RUN python3 /tmp/patch-gateway-setup-allowed-channels.py && rm /tmp/patch-gateway-setup-allowed-channels.py

# --- clarify tool: tolerate a bare question object (#88) ---
# Confirmed live, 2026-09-10 (a Telegram "Bonjour" test): Llama-3.1-8B
# calls `clarify` with `questions` as a bare object instead of the
# schema's required one-entry array on effectively every first clarify
# call, and hermes-agent's own loop guardrail then forces it to keep
# retrying tools rather than fall back to text — a single malformed
# call escalates into an 8-attempt, multi-minute loop for a message
# that never needed any tool. See docker/patch-clarify-questions-array.py
# and shared/model-notes.md's clarify-loop section for the full
# writeup.
COPY docker/patch-clarify-questions-array.py /tmp/patch-clarify-questions-array.py
RUN python3 /tmp/patch-clarify-questions-array.py && rm /tmp/patch-clarify-questions-array.py

# --- delegate_task/skill_manage: tolerate a string-encoded array (#102) ---
# Confirmed live, 2026-09-15, during agent-creation loop testing:
# Llama-3.1-8B sends delegate_task's `tasks` and skill_manage's
# `operations` as strings -- Python-literal syntax (single-quoted) for
# tasks, sometimes JSON-encoded for operations -- instead of a real
# array, the same class of mistake already fixed on `clarify` above.
# skill_manage had no string-recovery attempt at all (a bare type
# check); delegate_task only tried json.loads(), which always rejects
# Python-literal syntax. Both contribute to the delegate_task/
# skill_manage retry loops in issue #102 (not the only cause -- some
# captured failures were genuinely truncated mid-generation, which no
# parser fallback can fix). See docker/patch-delegate-task-tasks-array.py,
# docker/patch-skill-manage-operations-array.py, and issue #102.
COPY docker/patch-delegate-task-tasks-array.py /tmp/patch-delegate-task-tasks-array.py
RUN python3 /tmp/patch-delegate-task-tasks-array.py && rm /tmp/patch-delegate-task-tasks-array.py
COPY docker/patch-skill-manage-operations-array.py /tmp/patch-skill-manage-operations-array.py
RUN python3 /tmp/patch-skill-manage-operations-array.py && rm /tmp/patch-skill-manage-operations-array.py

# --- delegate_task: refuse to delegate agent-creation requests (#76) ---
# Confirmed live, 2026-09-15, via direct state.db inspection across 6
# sessions: on "crée un agent"/"create an agent" requests, the model calls
# delegate_task immediately, WITHOUT first consulting the
# agent-intent-interview skill despite SOUL.md's explicit routing
# instruction -- agent-intent-interview was mentioned 0 times across all 6
# sessions and their subagents. The spawned child never gets the
# "this is an agent-creation request" framing and picks an unrelated
# skill instead. A prompt-level fix (reinforcing the same routing
# instruction in SOUL.md) was tested the same day and had ZERO measured
# effect over 3 clean runs. This is also the structurally correct fix, not
# just a workaround: agent-intent-interview/agent-profile-builder are
# direct CLI actions for the CURRENT agent, never a task a subagent can
# carry out. See docker/patch-delegate-task-agent-creation-gate.py and
# issue #76.
COPY docker/patch-delegate-task-agent-creation-gate.py /tmp/patch-delegate-task-agent-creation-gate.py
RUN python3 /tmp/patch-delegate-task-agent-creation-gate.py && rm /tmp/patch-delegate-task-agent-creation-gate.py

# --- Recover a fabricated tool-call JSON blob from content (#101) ---
# Root cause confirmed live, 2026-09-15: Meta-Llama-3.1-8B-Instruct sometimes
# writes a tool call directly in chat content as JSON instead of issuing a
# real function call; llama.cpp's strict `peg-native` parser rejects this
# mixed shape outright, and this deployment's retry loop cannot reliably
# absorb it (6 consecutive full-conversation failures observed on one
# prompt in a single day). Paired with `--skip-chat-parsing` on
# llama-server (see macos-arm64/scripts/run-llama-server.sh,
# linux-x86_64-vps/docker-compose.yml) so the request never errors in the
# first place; this patch recovers the genuine tool-call intent from
# content instead of losing it. See
# docker/patch-chat-completions-recover-tool-call.py and issue #101.
COPY docker/patch-chat-completions-recover-tool-call.py /tmp/patch-chat-completions-recover-tool-call.py
RUN python3 /tmp/patch-chat-completions-recover-tool-call.py && rm /tmp/patch-chat-completions-recover-tool-call.py

# --- Verify-before-success, as a mandatory identity instruction (#48) ---
# The discretionary skill above (verify-before-success, #49) was tested
# live and found insufficient: the model doesn't reliably choose to
# consult it before writing a final summary. This appends to
# docker/SOUL.md instead — the base image's own always-injected identity
# file (copied verbatim into every fresh deployment's SOUL.md by the
# first-boot seed, same mechanism as the approvals default below, and
# unlike a skill, never skill-gated or discretionary). Verified live,
# 2026-09-04: 2/2 test runs of eval/regression-hallucinated-success.sh
# with this instruction produced an honest failure report instead of the
# false-success pattern seen in 2/2 runs without it. Small sample (see
# #37's own 4/6 variance finding for why this isn't proof of 100%
# reliability) but a real, consistent, positive signal — see
# shared/model-notes.md's #48 section.
RUN printf '\n\nBefore sending any message that states or implies a task succeeded, completed, or was created/saved/updated — list the tool calls that outcome depends on and check each one'"'"'s actual result field, not its intended purpose. If any of them returned an error or success:false, say so plainly and name what failed; never describe a failed tool call in the past tense as something that worked. A well-written, confident summary of a failed attempt is still a false report.' \
    >> /opt/hermes/docker/SOUL.md

# --- Delegation-fabrication stopgap (#48, spec'd 2026-09-04) ---
# The instruction above, and delegate_task's own upstream tool-description
# text (which already warns that child summaries are self-reports, not
# verified facts), both failed to prevent two real, confirmed cases of a
# delegated subagent fabricating a success narrative that the parent then
# repeated verbatim to the user — see shared/model-notes.md's #48 section
# and https://github.com/NousResearch/hermes-agent/issues/102977 (the
# upstream report filed for the durable fix). This is an unconditional
# stopgap, not a claim of a guarantee: any reply that relies on a
# delegate_task result gets a fixed disclaimer appended, regardless of
# what the subagent claimed — deliberately not conditioned on keyword-
# matching the subagent's text (considered and rejected: imperfect in
# both directions). Still instruction-based, so not provably 100%
# reliable, but a simpler compliance target ("always append this note
# when X happened") than the judgment call the three prior attempts
# asked for ("decide whether this claim is trustworthy").
RUN printf '\n\nWhenever your reply to the user relies on a delegate_task result — whether or not it appears to have succeeded — append this exact note at the end of your message: "Note: this involved a delegated subtask; please verify the reported outcome independently before relying on it." Add it every time delegate_task was used this turn, with no exception for results that look successful.' \
    >> /opt/hermes/docker/SOUL.md

# --- Zero-tool-call fabrication stopgap (#75, spec'd 2026-09-07) ---
# The two instructions above cover cases where a tool WAS called (and its
# result needs checking, or came from a delegated subagent). Found live,
# 2026-09-07, real Telegram conversation: a completely different failure
# mode where the model never calls any tool at all — asked to create,
# deploy, and test an agent, it instead described a plan in prose, wrote
# illustrative Python as inline chat text (never executed), said "je
# comprends" to an explicit "do the actual work" instruction, and then
# fabricated usage instructions for an agent that was never created.
# Confirmed directly against state.db: every message in that exchange had
# tool_calls IS NULL. Consistent with this deployment's own measured BFCL
# tool-calling reliability for this model (~53-55%, see
# shared/model-evaluation.md's #48/#55 section) — a live instance of the
# same weakness, manifesting as "never attempts a tool call" instead of
# "calls a tool and lies about the result".
RUN printf '\n\nWhen the user asks you to build, create, deploy, or set up something, and you have not called any tool this turn to actually do it, you have NOT done it — no matter how detailed or confident your description sounds. Writing example code in a chat message is not creating it. Describing steps is not performing them. Saying "je comprends" to a request to do real work is not doing the work. Never give usage instructions for something that does not yet exist. If real work is needed: either call the appropriate tool now, or say plainly and specifically what still needs to be done and why you have not done it yet.' \
    >> /opt/hermes/docker/SOUL.md

# --- Agent-creation skill routing (#76, spec'd 2026-09-07) ---
# #75's fix above stopped the fabrication, but retested live (2/2 runs,
# same message) surfaced a different, narrower gap: asked to create an
# agent, the model calls real tools now (progress), but picks a
# mismatched EXISTING skill (arxiv — academic papers — over the closer
# match competitor-news-monitor, and over the bundled agent-creation
# skills themselves) and stops there explaining how the user could use
# it, instead of ever calling agent-intent-interview/agent-profile-builder
# (confirmed present in the tool's own available_skills list both runs).
# Honest (no fabrication) but still doesn't do what was asked. This is a
# routing instruction, not a repeat of #75's "you must call a tool" ask.
RUN printf '\n\nWhen the user asks you to create or build an agent — not just to answer a question or look something up — that request maps specifically to the agent-intent-interview and agent-profile-builder skills. Start there. Recommending an existing unrelated skill (even a close-sounding one) instead of building the requested agent, or explaining to the user how they could do it themselves, does not fulfill an explicit '"'"'create an agent'"'"' request — it is a different, smaller answer to a bigger question.' \
    >> /opt/hermes/docker/SOUL.md

# --- No fabricated tool-call JSON in chat content (#101, spec'd 2026-09-13) ---
# #76's routing instruction above names agent-intent-interview and
# agent-profile-builder literally, and #48's delegation-disclaimer
# instruction tells the model to append a fixed note whenever a reply
# relies on a delegate_task result. Found live, 2026-09-12/13: combined,
# these make the model fabricate a fake single-function tool call as plain
# chat content, using a skill's own name as the function name (e.g.
# {"name": "agent-intent-interview", "parameters": {"questions": "[...]"}}),
# then append the mandated disclaimer text right after the JSON closes.
# llama-server's PEG_NATIVE chat-format parser rejects that mixed
# JSON-plus-prose output outright: "The model produced output that does
# not match the expected peg-native format" (an HTTP 500 from llama-server
# itself, confirmed by replaying the exact captured request directly
# against it). Reproduces with or without array-typed parameters, ruling
# out the initially-suspected upstream python_array() whitespace-before-
# comma parser bug (ggml-org/llama.cpp#27279 / #27295) as the cause here.
# Renaming the routing instruction's skill names, or reworking one skill's
# wording, only shifted the same fabrication to the next skill in the
# hand-off chain (agent-intent-interview -> agent-profile-builder) instead
# of fixing it — this is a general instruction because the failure is
# general, not per-skill. Verified live, 2026-09-13, macOS/Metal, current
# llama.cpp master (3057bb66c, build 10931): 4/4 identical agent-creation
# requests that previously 500'd every time completed without the
# peg-native error after adding this instruction. See
# https://github.com/ka8t/Hermes/issues/101 for the full trace.
RUN printf '\n\nYou never represent a tool call as JSON or code in your reply text — not a real one, not an attempted one, not an example. If you intend to use a tool (delegate_task included, and handing off to a skill such as agent-intent-interview or agent-profile-builder), call it through the real function-calling mechanism, not by writing its name and arguments as text in your message. If you are not calling a tool this turn, write your reply as plain prose with no JSON-shaped fragment resembling one.' \
    >> /opt/hermes/docker/SOUL.md

# --- Enterprise-safe approval default ---
# Appended (not replacing) the base image's own reference config, which the
# base image's first-boot seed copies verbatim into a fresh deployment's
# config.yaml — see shared/enterprise-safety.md for exactly what this does
# and does not cover. Every dangerous action requires an explicit human
# answer; it does not add delegated/group/SSO approval (Hermes has no such
# mechanism today — tracked separately, see that doc).
RUN printf '\n# --- ka8t/Hermes enterprise-safe default (see shared/enterprise-safety.md in github.com/ka8t/Hermes) ---\napprovals:\n  mode: manual\n' \
    >> /opt/hermes/cli-config.yaml.example
