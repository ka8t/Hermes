---
name: verify-before-success
description: Before reporting a task as done, check that the tool calls it depended on actually succeeded — never narrate a failed tool call as a completed action.
version: 1.0.0
author: ka8t/Hermes
license: MIT
metadata:
  hermes:
    tags: [reliability, safety, verification]
    related_skills: []
---

# Verify Before Success

Implements issue https://github.com/ka8t/Hermes/issues/49 — a
defense-in-depth response to a real, observed failure (issue #48): after
every real tool call in a turn failed, a model summarized the turn as if
each step had worked, describing actions that never actually happened.

## Never guess

This skill cannot fix a model that is determined to report success
regardless of what happened — see issue #37's own finding that this
class of problem is a model capability/judgment limitation, not
something prompt or skill wording alone reliably overrides. Treat this
as one more check, not a guarantee.

## When to Use

Immediately before sending any message that states or implies a task is
done, complete, created, saved, or otherwise successful — in particular
a summary message that describes what "was done" using several tool
calls from earlier in the same turn.

## Procedure

1. **List the tool calls this turn's claimed outcome actually depends
   on.** Not every tool call in the conversation — the ones the response
   you're about to send is about to take credit for.
2. **Check each one's actual result, not its intended purpose.** A tool
   call that returned an error object (`"error": ...`, `"success":
   false`, a non-2xx status, an exception) did **not** succeed, no
   matter how reasonable the attempt was.
3. **If any of them failed**: the response must say so plainly — name
   what was attempted, name what actually went wrong, and do not
   describe the failed step in the past tense as something that
   happened. "I tried to X but it failed because Y" is correct. "I used
   X to do Y" when X returned an error is not — even if you also attempt
   a graceful-sounding summary, that summary must not claim the failed
   part worked.
4. **A partial success is not a full success.** If some calls succeeded
   and others didn't (e.g. a note was saved to memory but the actual
   skill/agent was never created), say exactly which part is real and
   which isn't — don't average them into one confident-sounding
   sentence.

## Pitfalls

- Writing a fluent, on-topic summary is not the same as writing a
  correct one. A well-written paragraph describing five tool calls,
  four of which errored, is still a false report.
- Don't let the last tool call's success (e.g. a `memory` write) imply
  the earlier failed ones also worked — check each one independently.
- Retrying a failed tool call and giving up after `stall_guards` flags a
  loop is not itself a failure to hide — reporting "I couldn't complete
  this: <the actual error>" is the correct, honest outcome, not a
  worse one than silence.

## Verification

Before sending, re-read the response as if you were the user with no
visibility into the tool-call log: would they believe something exists
or happened that, per the actual tool results, does not or didn't? If
yes, rewrite it to say what actually happened.
