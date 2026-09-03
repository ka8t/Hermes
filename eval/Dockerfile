# Runs BFCL (issue #29) with all installs contained inside this image's own
# filesystem — never on the host, under this repo's own eval/ folder.
#
# Why: a Python venv's thousands of small package files, created directly
# under eval/ on a Mac with iCloud Drive's "Optimize Mac Storage" enabled
# (syncing ~/Documents, evicting local copies of files under storage
# pressure and re-fetching on demand), got evicted and then failed to
# re-hydrate — confirmed live 2026-09-03 (`import transformers` raised
# `TimeoutError: [Errno 60] Operation timed out`, reproduced with a plain
# `wc -l` on the same file). The repo itself must stay fully synced under
# ~/Documents, with no per-file iCloud exclusion and no relocated install
# directory (both explicitly ruled out — see #51) — containerizing the
# install means the affected files never exist on the host at all. See
# ../shared/model-evaluation.md.
#
# Build: docker build -t hermes-eval-bfcl -f eval/Dockerfile eval/
# (done automatically by ./setup-bfcl.sh)
FROM python:3.11-slim

# entrypoint.sh's proxy health-check needs curl — not in python:3.11-slim by default.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

# bfcl-eval's Qwen support imports soundfile at module load time even
# though this deployment never uses Qwen's API path (crashes on startup
# for every model otherwise); its local-inference handler imports
# transformers directly without declaring it as a dependency. Found
# live-testing this, not documented upstream — see
# ../shared/model-evaluation.md.
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir bfcl-eval soundfile transformers

WORKDIR /eval
COPY model_alias_proxy.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
