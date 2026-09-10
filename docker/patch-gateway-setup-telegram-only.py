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
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/hermes_cli/gateway.py")
text = TARGET.read_text()

OLD = '''                "install_hint": entry.install_hint,
                "_registry_entry": entry,
            }
        )
    return platforms'''

NEW = '''                "install_hint": entry.install_hint,
                "_registry_entry": entry,
            }
        )
    # ka8t/Hermes: only Telegram is implemented, tested, and documented for
    # this deployment (see shared/telegram-setup.md) -- filter the setup
    # menu down to it instead of offering channels that would silently go
    # unsupported. See docker/patch-gateway-setup-telegram-only.py.
    return [p for p in platforms if p["key"] == "telegram"]'''

if OLD not in text:
    sys.exit(
        "gateway.py's _all_platforms() return block doesn't match the "
        "expected text -- the base image likely changed upstream. Re-check "
        "shared/telegram-setup.md and update this patch."
    )

TARGET.write_text(text.replace(OLD, NEW, 1))
print("Patched gateway.py: _all_platforms() now returns Telegram only.")
