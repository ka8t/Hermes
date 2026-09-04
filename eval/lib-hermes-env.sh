# Shared by eval/regression-*.sh — lets each script run against either a
# Docker Hermes container or a native install without a separate copy of
# the script per environment. Source this, don't run it directly.
#
# HERMES_MODE: "docker" (default) or "native"
#   docker: $HERMES_CONTAINER (default "hermes"), reached via `docker exec`
#   native: $HERMES_HOME (default "$HOME/.hermes"), $HERMES_BIN (default
#           "hermes" on PATH) — state.db lives at $HERMES_HOME/state.db
# HERMES_MODEL_ARGS: optional extra args appended to `hermes -z`, e.g.
#   "-m qwen3-8b --provider custom" for a model-comparison run (#55).
set -euo pipefail

HERMES_MODE="${HERMES_MODE:-docker}"
HERMES_CONTAINER="${HERMES_CONTAINER:-hermes}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_BIN="${HERMES_BIN:-hermes}"
HERMES_MODEL_ARGS="${HERMES_MODEL_ARGS:-}"

hermes_env_check() {
  case "${HERMES_MODE}" in
    docker)
      if ! docker exec "${HERMES_CONTAINER}" true 2>/dev/null; then
        echo "Docker container '${HERMES_CONTAINER}' not reachable — set \$HERMES_CONTAINER or start it." >&2
        exit 2
      fi
      ;;
    native)
      if ! command -v "${HERMES_BIN}" >/dev/null 2>&1; then
        echo "'${HERMES_BIN}' not found on PATH — set \$HERMES_BIN or run ./install-hermes-native.sh." >&2
        exit 2
      fi
      if [ ! -f "${HERMES_HOME}/state.db" ]; then
        echo "${HERMES_HOME}/state.db not found — has the gateway/CLI ever run? (\$HERMES_HOME=${HERMES_HOME})" >&2
        exit 2
      fi
      ;;
    *)
      echo "Unknown \$HERMES_MODE '${HERMES_MODE}' — expected 'docker' or 'native'." >&2
      exit 2
      ;;
  esac
}

# Launches `hermes -z "$1"` in the background, backgrounded the same way
# in both modes (nohup-equivalent via disown-free `&`, matching how this
# repo's own manual testing found background-process tracking to be more
# reliable via `docker exec ... &` / plain `&` than more elaborate
# wrappers). Prints nothing; sets $HERMES_RUN_PID.
hermes_launch_oneshot() {
  local prompt="$1"
  case "${HERMES_MODE}" in
    docker)
      # shellcheck disable=SC2086
      docker exec "${HERMES_CONTAINER}" hermes -z "${prompt}" ${HERMES_MODEL_ARGS} > /tmp/regression-oneshot.log 2>&1 &
      ;;
    native)
      # shellcheck disable=SC2086
      "${HERMES_BIN}" -z "${prompt}" ${HERMES_MODEL_ARGS} > /tmp/regression-oneshot.log 2>&1 &
      ;;
  esac
  HERMES_RUN_PID=$!
}

hermes_kill_oneshot() {
  kill "${HERMES_RUN_PID}" 2>/dev/null || true
  case "${HERMES_MODE}" in
    docker) pkill -f "docker exec ${HERMES_CONTAINER} hermes -z" 2>/dev/null || true ;;
    native) pkill -f "${HERMES_BIN} -z" 2>/dev/null || true ;;
  esac
}

# Runs a Python snippet against state.db in whichever environment is
# active. The snippet reads state.db from a variable named `DB_PATH`
# already in scope — callers don't need to know the real path.
hermes_query_db() {
  local py_snippet="$1"
  case "${HERMES_MODE}" in
    docker)
      docker exec "${HERMES_CONTAINER}" python3 -c "
import sqlite3
DB_PATH = '/opt/data/state.db'
${py_snippet}
" 2>/dev/null || true
      ;;
    native)
      python3 -c "
import sqlite3
DB_PATH = '${HERMES_HOME}/state.db'
${py_snippet}
" 2>/dev/null || true
      ;;
  esac
}
