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

# --- Enterprise-safe approval default ---
# Appended (not replacing) the base image's own reference config, which the
# base image's first-boot seed copies verbatim into a fresh deployment's
# config.yaml — see shared/enterprise-safety.md for exactly what this does
# and does not cover. Every dangerous action requires an explicit human
# answer; it does not add delegated/group/SSO approval (Hermes has no such
# mechanism today — tracked separately, see that doc).
RUN printf '\n# --- ka8t/Hermes enterprise-safe default (see shared/enterprise-safety.md in github.com/ka8t/Hermes) ---\napprovals:\n  mode: manual\n' \
    >> /opt/hermes/cli-config.yaml.example
