#!/usr/bin/env python3
"""Build-time patch — restrict `hermes gateway setup`'s platform menu to
Telegram only.

Upstream's `_all_platforms()` (hermes_cli/gateway.py) returns every built-in
and plugin-registered messaging platform (Discord, WhatsApp, Signal, Matrix,
IRC, Mattermost, Weixin, Slack, and more) for the interactive setup wizard's
picker (see gateway_setup()'s "Select a platform to configure" loop). This
repo has only implemented, tested, and documented Telegram end-to-end (see
../shared/telegram-setup.md) — WhatsApp and Teams have setup docs but are
explicitly marked unverified against a real deployment, and the remaining
platforms aren't documented here at all. Letting a user pick one of those
from the wizard leads to a channel that looks configured but was never
verified to actually work on this stack, with no guidance if it doesn't.

Filtering the menu down to Telegram is simpler and more robust than trying
to grey out individual entries in the upstream curses picker (prompt_choice)
— it doesn't depend on that rendering code's internals, which aren't ours to
maintain across base-image updates.

Anchored on the function boundary (``def _all_platforms(`` / the next
``def``), not on its internal formatting — found live, 2026-09-10, that
this exact function got cosmetically reformatted upstream (multi-line
dict literal collapsed to one line, a `hide_matrix` local added) between
two `:latest` pulls hours apart, breaking a patch that matched the old
literal text. Matching on the LAST bare ``return platforms`` inside the
function body survives that kind of reformatting; only the function's
own name and its use of ``return platforms`` as the real (non-early-exit)
return need to stay stable.

Unlike patch-web-search-schema.py (a formal JSON-schema contract Nous
has no reason to reformat casually), this one fails SOFT: an
unmatched pattern here logs a warning and leaves the upstream menu
un-filtered rather than failing the whole multi-arch build (found
live, 2026-09-10: a hard failure here blocked ghcr.io/ka8t/hermes from
publishing ANY change, including unrelated ones bundled in the same
push, over what is ultimately a cosmetic UX filter, not a functional or
security fix).
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/hermes_cli/gateway.py")
text = TARGET.read_text()

FUNC_START = "def _all_platforms("
NEXT_DEF = "\ndef "

start = text.find(FUNC_START)
if start == -1:
    print(
        "WARNING: _all_platforms() not found in gateway.py -- the base "
        "image likely changed upstream. Skipping the Telegram-only menu "
        "filter (upstream's full platform picker will be shown). Re-check "
        "shared/telegram-setup.md and update this patch.",
        file=sys.stderr,
    )
    sys.exit(0)

end = text.find(NEXT_DEF, start + len(FUNC_START))
if end == -1:
    end = len(text)

func_body = text[start:end]

MARKER = "    return platforms"
last_idx = func_body.rfind(MARKER)
if last_idx == -1:
    print(
        "WARNING: no 'return platforms' found inside _all_platforms() -- "
        "the base image likely changed upstream. Skipping the "
        "Telegram-only menu filter (upstream's full platform picker will "
        "be shown). Re-check shared/telegram-setup.md and update this "
        "patch.",
        file=sys.stderr,
    )
    sys.exit(0)

REPLACEMENT = (
    "    # ka8t/Hermes: only Telegram is implemented, tested, and documented\n"
    "    # for this deployment (see shared/telegram-setup.md) -- filter the\n"
    "    # setup menu down to it instead of offering channels that would\n"
    "    # silently go unsupported. See\n"
    "    # docker/patch-gateway-setup-telegram-only.py.\n"
    '    return [p for p in platforms if p["key"] == "telegram"]'
)

patched_func = func_body[:last_idx] + REPLACEMENT + func_body[last_idx + len(MARKER):]
TARGET.write_text(text[:start] + patched_func + text[end:])
print("Patched gateway.py: _all_platforms() now returns Telegram only.")
