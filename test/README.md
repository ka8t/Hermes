# Tests

This is an infrastructure repo (scripts, Docker Compose files, YAML
configs), not an application with unit-testable functions, so "tests" here
are integration checks against the actual public seams a user interacts
with — the same seams described in each platform's README (`/health`,
`/v1/models`, `/v1/chat/completions`, and the scripts a user is told to run)
— rather than mocks of internal behavior.

| Script | What it checks | Runs in CI | Needs |
|---|---|---|---|
| `lint.sh` | Every `.sh` file parses; every `docker-compose*.yml` / `*.yaml.example*` is valid YAML; each platform's `config.yaml.example` `model.default` matches an ID actually defined in its `models.yaml.example` | Yes | Nothing (no network, no containers) |
| `smoke-vps.sh` | The **real** `linux-x86_64-vps/docker-compose.yml` `llama-swap` service starts healthy, lists its model over `/v1/models`, and answers a real `/v1/chat/completions` request — with a tiny model swapped in for speed | Yes | Docker |
| `smoke-macos.sh` | The same wiring (`download-prebuilt-llama-server.sh` → `download-llama-swap.sh` → `run-llama-swap.sh` → a real completion), natively with Metal | No — needs an actual Apple Silicon Mac | macOS, Apple Silicon |

Neither smoke test touches the `hermes` container or Telegram — that's
Hermes's own gateway, a seam this repo doesn't own or need to re-verify;
these tests stop at "does this repo's model-serving wiring actually serve a
model," which is the part unique to this repo.

## Running locally

```bash
./test/lint.sh
./test/smoke-vps.sh      # needs Docker; downloads a ~350MB test model once
./test/smoke-macos.sh    # Apple Silicon only; no-ops (exit 0) elsewhere
```

Both smoke tests clean up after themselves (containers, `.env`, `data/`) —
they never touch your real `.env` or `data/` if you have one, since they
work from a copy of `.env.example` and delete it on exit.
