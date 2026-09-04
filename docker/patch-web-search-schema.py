#!/usr/bin/env python3
"""Build-time patch for issue #50 — see docker/Dockerfile's comment for the
full root-cause writeup (llama-server has hardcoded, name-based special
handling for a tool literally called "web_search", validating the model's
call against its own internal query-only contract regardless of whatever
schema the client actually declares for that name — confirmed directly via
`strings` on the compiled llama-server binary, which contains both the
literal string "web_search" and the generic JSON-schema-validator error
vocabulary next to it).

Removing "limit" from the schema entirely (not just from "required" — that
was tried first and did NOT fix it, since the collision is on the tool name
itself, not on which properties are required) means the model is never
offered a parameter that triggers the collision. The tool keeps its default
5-result behavior (see web_search_tool's own default), just without the
model's ability to request a different count.
"""
import pathlib
import sys

TARGET = pathlib.Path("/opt/hermes/tools/web_tools.py")
text = TARGET.read_text()

OLD = '''            "query": {
                "type": "string",
                "description": "The search query to look up on the web. You may include backend-supported operators such as site:example.com, filetype:pdf, intitle:word, -term, or \\"exact phrase\\"."
            },
            "limit": {
                "type": "integer",
                "description": "Maximum number of results to return. Defaults to 5.",
                "minimum": 1,
                "maximum": 100,
                "default": 5
            }
        },
        "required": ["query"]'''

NEW = '''            "query": {
                "type": "string",
                "description": "The search query to look up on the web. You may include backend-supported operators such as site:example.com, filetype:pdf, intitle:word, -term, or \\"exact phrase\\"."
            }
        },
        "required": ["query"]'''

if OLD not in text:
    sys.exit(
        "web_tools.py's WEB_SEARCH_SCHEMA block doesn't match the expected "
        "text — the base image likely changed upstream. Re-check "
        "shared/model-notes.md's #50 section and update this patch."
    )

TARGET.write_text(text.replace(OLD, NEW, 1))
print("Patched web_tools.py: removed 'limit' from web_search's schema (#50).")
