# Managing models (switch the one model this deployment runs)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

Both configurations run `llama-server` directly, no proxy in front —
this deployment always runs exactly **one** model, always loaded, never
swapped at runtime (see `docs/ARCHITECTURE.md`, 2026-09-15: this repo
used to put [llama-swap](https://github.com/mostlygeek/llama-swap) in
front of it for exactly that purpose, but that capability went unused
here, and llama-swap's own separate update lifecycle caused a real
incident — see issue #101). **You switch models by editing `.env` and
restarting `llama-server`** — Hermes itself needs no changes as long as
`config.yaml`'s `model.default` keeps matching.

## Switching the model

1. Download another GGUF into `./models/` (see
   [`model-notes.md`](model-notes.md) for where to find one;
   `./scripts/download-model.sh` only ever fetches the default one, so grab
   another file yourself with `curl`, matching the same
   `https://huggingface.co/<repo>/resolve/main/<file>` URL shape). **Before
   adopting any model outside this repo's tested default, run the raw
   tool-calling `curl` test in [`model-notes.md`](model-notes.md)** — this
   repo shipped a model that looked fine and had broken tool-calling in
   llama.cpp, found only by that test.
2. Edit `MODEL_FILE` in `.env` to the new file's name.
3. Restart `llama-server` to load it:
   - macOS (native): stop `./scripts/run-llama-server.sh` (Ctrl-C, or
     `launchctl unload`/`load` if running as a service) and start it again.
   - VPS (Docker): `docker compose up -d --build llama-server`.
4. If the new model's context needs differ from the default 65536, also
   update `LLAMA_CTX_SIZE` in `.env` before restarting.

There's no "switch model from inside Hermes" command in this setup —
`model.default` in `config.yaml` is fixed (see below), because there's
only ever one model actually running to route to.

## Renaming the default

Hermes's `model.default` in `data/config.yaml` doesn't need to match
anything on the `llama-server` side — a single-model `llama-server`
ignores the `model` field in requests entirely and just serves whatever
it was started with. This repo keeps `model.default: llama-3.1-8b-instruct`
as a stable, descriptive label regardless of which `.gguf` is actually
loaded; there's no functional requirement to change it when you switch
models, only a documentation one (update it if you want the label to
stay accurate for the next person reading `config.yaml`).

## Inspecting what's running

`curl http://127.0.0.1:8080/v1/models` (macOS) or the VPS's internal
`llama-server:8080` from inside the `hermes` container — `llama-server`
itself exposes an OpenAI-compatible `/v1/models` and `/health`, no
separate UI. For a live chat playground against the model directly
(bypassing Hermes entirely — useful for telling apart "Hermes is
broken" from "the model itself is broken"), `llama-server` serves its
own minimal web UI at `/` when reached with a browser.

## Sources

- llama-server CLI flags and HTTP API: [github.com/ggml-org/llama.cpp/tree/master/tools/server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
- Hermes `custom` provider and named providers: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
