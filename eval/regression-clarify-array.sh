#!/usr/bin/env bash
# Regression gate for issue #88 (clarify tool: bare question object):
# checks that the build-time patch (docker/patch-clarify-questions-array.py)
# is actually present and working in a running deployment's image, not
# just that it exists as a source file. See shared/model-notes.md's
# "`clarify` itself root-caused and fixed" section for the full
# root-cause writeup this follows up on.
#
# Deliberately a unit-level check of the patched function, not an
# end-to-end model-behavior test like regression-goal-drift.sh /
# regression-hallucinated-success.sh: whether the MODEL happens to call
# `clarify` with a bare object on any given run is sampling-variance-
# dependent (see model-notes.md's #37 variance finding) and wouldn't
# reliably test the fix itself — this instead directly exercises
# `_normalize_questions()` with the exact malformed shape reproduced
# live, 2026-09-10, so it's deterministic and doesn't need a live model
# call at all.
#
# Runs against either a Docker container or a native install — see
# eval/lib-hermes-env.sh for $HERMES_MODE and the other env vars this
# reads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-hermes-env.sh
source "${SCRIPT_DIR}/lib-hermes-env.sh"

hermes_env_check

# shellcheck disable=SC2016
CHECK_PY='
import sys

sys.path.insert(0, "/opt/hermes")
sys.path.insert(0, "/opt/hermes/tools")
from clarify_tool import _normalize_questions

failures = []

# The exact malformed shape reproduced live, 2026-09-10 (a Telegram
# "Bonjour" test): the fix must accept this.
normalized, error = _normalize_questions({"question": "Bonjour, comment puis-je aider ?"})
if error is not None or not normalized or normalized[0]["question"] != "Bonjour, comment puis-je aider ?":
    failures.append(f"bare dict: expected success, got error={error!r} normalized={normalized!r}")

# A genuinely valid call must still work (the fix must not have widened
# tolerance too far).
normalized, error = _normalize_questions([{"question": "Q1"}])
if error is not None or not normalized or normalized[0]["question"] != "Q1":
    failures.append(f"valid array: expected success, got error={error!r} normalized={normalized!r}")

# A genuinely invalid call must still be rejected with the original
# error message (not silently accepted).
normalized, error = _normalize_questions("not valid")
if error != "questions must be an array of question objects." or normalized is not None:
    failures.append(f"invalid string: expected the original rejection, got error={error!r} normalized={normalized!r}")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    sys.exit(1)
print("PASS: _normalize_questions() accepts a bare question object, still validates correctly otherwise.")
'

case "${HERMES_MODE}" in
  docker)
    docker exec "${HERMES_CONTAINER}" python3 -c "${CHECK_PY}"
    ;;
  native)
    python3 -c "${CHECK_PY}"
    ;;
esac
