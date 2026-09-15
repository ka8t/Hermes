#!/usr/bin/env python3
"""Build-time patch — recover a fabricated tool-call JSON blob written directly in
chat content, instead of crashing on it.

Root cause (issue #101, confirmed live 2026-09-15 across dozens of reproductions,
macOS/Metal): Meta-Llama-3.1-8B-Instruct sometimes writes its tool-call intent
directly in chat content as ``{"name": "...", "parameters"|"arguments": {...}}``
instead of issuing a real function call. llama.cpp's strict `peg-native`
chat-format parser rejects this mixed shape outright
(`openai.APIError: ... does not match the expected peg-native format`), which
this deployment's own retry loop cannot reliably absorb -- 6 consecutive
full-conversation attempts on the same prompt were observed failing this way
in a single day of testing (see shared/model-notes.md).

Fix, in two parts:
1. `llama-server` is started with `--skip-chat-parsing` (see
   macos-arm64/scripts/run-llama-server.sh /
   linux-x86_64-vps/docker-compose.yml), which forces a pure content parser --
   the model's raw output (including any attempted tool call) always lands in
   `message.content`, and the request never errors. Confirmed via raw `curl`
   test: same fabricated-JSON shape, `finish_reason: "stop"`, HTTP 200.
2. `ChatCompletionsTransport.normalize_response()` (used for ANY OpenAI-
   compatible provider, not just llama-server) recovers that JSON as a real,
   executed tool call when the provider never populated `tool_calls` itself --
   so the genuine tool-call intent still gets acted on instead of being lost
   to a parse error or shown to the user as inert JSON.

Verified live, 2026-09-15: 4 consecutive full `hermes -z` runs against the
exact prompt that reliably crashed before this fix -- zero peg-native errors
in any of them (previously near-100% reproduction). A separate, pre-existing
bug was exposed as a result (filed separately) -- sessions now run long enough
for the model's own retry loops to repeat an identical tool call many times,
and `agent/message_sanitization.py`'s `deterministic_call_id()` intentionally
hashes `(name, arguments, index)` for prompt-cache stability, so repeated
identical calls collide on the same synthetic id (confirmed live: one call_id
shared by 34 distinct assistant messages in one session) -- eventually
tripping an unrelated "Cannot have 2 or more assistant messages" 400 from a
repair pass that assumes call ids are unique. Not fixed by this patch; not
caused by it either -- the collision mechanism predates this change and was
simply never reachable before (sessions always crashed on peg-native first).
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/agent/transports/chat_completions.py")
text = TARGET.read_text()

IMPORT_OLD = '''import json
from typing import Any
'''

IMPORT_NEW = '''import json
import re
from typing import Any
'''

MODULE_CONSTS_OLD = '''
class ChatCompletionsTransport(ProviderTransport):
'''

MODULE_CONSTS_NEW = '''
# ka8t/Hermes: raw chat-template artifacts --skip-chat-parsing exposes when a
# recovered tool call's remaining content is nothing but this -- see
# _recover_fabricated_tool_call (issue #101).
_JUNK_REMAINDER_RE = re.compile(r"^(assistant|user|system)$|^```(?:\\w+)?\\s*```$", re.IGNORECASE)
_LEADING_ROLE_MARKER_RE = re.compile(r"^(assistant|user|system)\\s*:?\\s*\\n*", re.IGNORECASE)


class ChatCompletionsTransport(ProviderTransport):
'''

METHODS_OLD = '''
    def normalize_response(self, response: Any, **kwargs) -> NormalizedResponse:
'''

METHODS_NEW = '''
    def _find_json_object(self, text: str, start: int = 0) -> "tuple[int, int] | None":
        """Span of the first top-level ``{...}`` object in ``text`` from ``start``,
        respecting string literals so braces inside quoted strings don't confuse the
        scan. Returns ``(open_idx, close_idx)`` (inclusive) or ``None`` -- ``None`` also
        for unbalanced input (e.g. a response truncated mid-JSON), which is the correct
        outcome: nothing safe to recover there."""
        open_idx = text.find("{", start)
        if open_idx == -1:
            return None
        depth = 0
        in_string = False
        escape = False
        for i in range(open_idx, len(text)):
            ch = text[i]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return open_idx, i
        return None

    @staticmethod
    def _parse_tool_call_json(raw: str) -> "dict | None":
        """``raw`` (a balanced ``{...}`` span) as a ``{"name": ..., "parameters"|
        "arguments": {...}}`` dict, tolerating Python-literal (single-quoted) syntax
        the same way the delegate_task/skill_manage tool patches do -- or ``None`` if
        it doesn't parse or doesn't have that shape."""
        try:
            parsed = json.loads(raw)
        except (ValueError, TypeError):
            import ast
            try:
                parsed = ast.literal_eval(raw)
            except (ValueError, SyntaxError):
                return None
        if not isinstance(parsed, dict):
            return None
        name = parsed.get("name")
        if not isinstance(name, str) or not name.strip():
            return None
        args = parsed.get("parameters", parsed.get("arguments"))
        if args is None:
            args = {}
        if not isinstance(args, dict):
            return None
        return {"name": name, "arguments": args}

    def _recover_fabricated_tool_call(self, content: str) -> "tuple[ToolCall | None, str | None]":
        """ka8t/Hermes: a weak model sometimes writes its tool-call intent directly in
        chat content as ``{"name": "...", "parameters"|"arguments": {...}}`` instead of
        a real function call -- observed live with llama.cpp's strict `peg-native`
        chat-format parser rejecting this exact mixed shape outright (`openai.APIError:
        ... does not match the expected peg-native format`, issue #101, reproduced
        repeatedly with this deployment's default model). Recovering it here, once,
        generically for any OpenAI-compatible provider, means a genuine tool-call intent
        gets executed instead of being lost to a parse error or shown to the user as
        inert JSON. Conservative by construction -- returns ``(None, None)`` unless the
        text contains a JSON object with exactly this shape, since ordinary prose
        essentially never does.

        Only the FIRST such object becomes the real, executed tool call. Observed live:
        a generation sometimes strings several of these together in one response
        (``{"name": "skill_view", ...}; {"name": "execute_code", ...}; {"name":
        "browser_vault_save_login", ...}``) -- whether this is deliberate or not isn't
        knowable from the text alone, but in the captured examples the later fragments
        were incoherent with each other (one referenced a Python API,
        `hermes.skill.create_daily_reminder()`, that doesn't exist anywhere in this
        codebase) and unrelated to the request. Executing an unverified multi-action
        bundle from a model with a measured ~52% BFCL score on genuine parallel calls
        is a real risk independent of intent -- one of the actions seen live was a
        password-vault write. Every object after the first matching this shape is
        stripped as noise -- never shown to the user, never executed -- while genuine
        surrounding prose (e.g. the mandatory delegated-subtask disclaimer) is kept.
        """
        if not isinstance(content, str) or not content.strip():
            return None, None
        first_call = None
        pieces: list[str] = []
        cursor = 0
        while True:
            span = self._find_json_object(content, cursor)
            if span is None:
                pieces.append(content[cursor:])
                break
            start, end = span
            pieces.append(content[cursor:start])
            raw = content[start:end + 1]
            parsed = self._parse_tool_call_json(raw)
            if parsed is not None:
                if first_call is None:
                    first_call = parsed
                # else: a later fragment shaped like a tool call -- drop it, don't execute or show it.
            else:
                pieces.append(raw)  # not a tool call after all -- keep as ordinary text.
            cursor = end + 1
        if first_call is None:
            return None, None
        remaining = "".join(pieces).strip()
        # ka8t/Hermes: --skip-chat-parsing (issue #101) exposes raw chat-template
        # leakage the native parser used to strip -- observed live: the word
        # "assistant" (the next turn's role marker, generated as literal text, no
        # special tokens involved -- confirmed via hex dump), either alone trailing
        # the JSON, or as a leading prefix before otherwise-genuine trailing prose
        # (e.g. "assistant\\n\\n Note: this involved a delegated subtask..."), and an
        # empty ```json``` fence. None of this is real content; keeping it would
        # show the user garbage and, combined with an empty synthetic tool result,
        # risks two effectively-empty "assistant" turns in a row.
        remaining = _LEADING_ROLE_MARKER_RE.sub("", remaining).strip()
        # Separators left over between stripped fragments (";", ",", stray whitespace).
        remaining = re.sub(r"^[;,\\s]+", "", remaining).strip()
        if remaining and _JUNK_REMAINDER_RE.match(remaining):
            remaining = ""
        return (
            ToolCall(id=None, name=first_call["name"],
                     arguments=json.dumps(first_call["arguments"], ensure_ascii=False),
                     provider_data={"recovered_from_content": True}),
            remaining or None,
        )

    def normalize_response(self, response: Any, **kwargs) -> NormalizedResponse:
'''

RECOVERY_CALL_OLD = '''                    finish_reason = "content_filter"

'''

RECOVERY_CALL_NEW = '''                    finish_reason = "content_filter"

        # ka8t/Hermes: see _recover_fabricated_tool_call -- issue #101.
        if not tool_calls:
            recovered, remaining = self._recover_fabricated_tool_call(content)
            if recovered is not None:
                tool_calls = [recovered]
                content = remaining
                finish_reason = "tool_calls"

'''

_missing = []
for _label, _old in (("import", IMPORT_OLD), ("module_consts", MODULE_CONSTS_OLD), ("methods", METHODS_OLD), ("recovery_call", RECOVERY_CALL_OLD)):
    if _old not in text:
        _missing.append(_label)
if _missing:
    sys.exit(
        f"chat_completions.py doesn't match the expected text ({', '.join(_missing)}) "
        "-- the base image likely changed upstream. Re-check issue #101 and update this patch."
    )

text = text.replace(IMPORT_OLD, IMPORT_NEW, 1)
text = text.replace(MODULE_CONSTS_OLD, MODULE_CONSTS_NEW, 1)
text = text.replace(METHODS_OLD, METHODS_NEW, 1)
text = text.replace(RECOVERY_CALL_OLD, RECOVERY_CALL_NEW, 1)

TARGET.write_text(text)
print("Patched chat_completions.py: normalize_response() now recovers a fabricated tool-call JSON blob from content instead of leaving it unrecovered.")
