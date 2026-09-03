---
name: web-search-query-only
description: Call web_search with only the query parameter — never limit — until a confirmed llama-server bug rejecting that valid optional parameter is fixed upstream.
version: 1.0.0
author: ka8t/Hermes
license: MIT
metadata:
  hermes:
    tags: [reliability, web-search, workaround]
    related_skills: []
---

# Web Search: Query Only

Implements issue https://github.com/ka8t/Hermes/issues/50 — a confirmed
llama-server bug, not a Hermes or model bug.

## The confirmed bug

`web_search`'s own declared schema allows an optional `limit` parameter
(integer, 1-100, default 5) alongside the required `query`. Captured
directly (request logged, response logged): llama-server rejects **any**
call that includes `limit`, even though the schema explicitly allows it
— `HTTP 500: Parameters of tool web_search must only have these
properties:query`. This happens regardless of what value `limit` is set
to; only its presence matters. This is llama-server's own tool-call
validation only honoring `required` properties and silently ignoring
valid optional ones — reported upstream, not fixed yet.

## When to Use

Any time you are about to call `web_search`.

## Procedure

Call `web_search` with **only** the `query` property. Never include
`limit`, even though the tool's schema says it's allowed and even though
you may want to control the result count — on this deployment, doing so
causes the call to fail outright with a confusing provider error, not a
graceful "invalid parameter" tool response you could recover from. If
you need fewer or more results than the default, filter or truncate the
results yourself after the (unfiltered) call returns, rather than trying
to constrain the call itself.

## Pitfalls

- The schema you see for `web_search` will still show `limit` as a
  valid, documented parameter — that's accurate as far as Hermes is
  concerned; the rejection happens one layer down, in llama-server, not
  in anything Hermes told you.
- This is not a retryable error — using `limit` fails 100% of the time
  on this build, not intermittently. Don't retry the same call with
  `limit` again after it fails once.

## Verification

Before sending a `web_search` call, confirm its arguments object
contains exactly one key: `query`. If a draft call has a second key,
remove it before calling.
