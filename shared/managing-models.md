# Managing models (add / switch / remove)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

Both configurations put [llama-swap](https://github.com/mostlygeek/llama-swap)
in front of llama.cpp instead of running `llama-server` directly. llama-swap
reads one YAML file listing every model you want available, and loads the
right `llama-server` process on demand based on the `model` field of the
incoming request — which is exactly the field Hermes's `/model` command (and
its model selector) already sends. **You manage models by editing that one
file**; Hermes itself needs no changes.

- macOS: `macos-arm64/config/models.yaml` (copied from `models.yaml.example`)
- VPS: `linux-x86_64-vps/data/models.yaml` (copied from `config/models.yaml.example`)

Both containers/processes are started with `-watch-config`, so **edits take
effect immediately** — no restart needed.

## Adding a second model

1. Download another GGUF into `./models/` (see
   [`model-notes.md`](model-notes.md) for where to find one;
   `./scripts/download-model.sh` only ever fetches the default one, so grab
   additional files yourself with `curl`, matching the same
   `https://huggingface.co/<repo>/resolve/main/<file>` URL shape).
2. Add a second entry under `models:` in `models.yaml`, with its own ID:

   ```yaml
   models:
     "llama-3.1-8b-instruct":
       name: "Llama 3.1 8B Instruct (default)"
       cmd: ... # unchanged
       ttl: 600

     "llama-3.1-70b-instruct":
       name: "Llama 3.1 70B Instruct (bigger, slower)"
       cmd: |
         ${env.LLAMA_SERVER_BIN} --port ${PORT}
         --model ./models/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf
         --ctx-size ${env.LLAMA_CTX_SIZE}
         --jinja
       ttl: 600
   ```

   (on the VPS, `cmd` starts with `/app/llama-server` instead of
   `${env.LLAMA_SERVER_BIN}`, and add `--threads ${env.LLAMA_THREADS}` — copy
   the shape of the existing `llama-3.1-8b-instruct` entry in that file
   rather than the macOS one above). **Before adopting any model outside
   this repo's tested default, run the raw tool-calling `curl` test in
   [`model-notes.md`](model-notes.md)** — this repo shipped a model that
   looked fine and had broken tool-calling in llama.cpp, found only by that
   test.

3. That's it. Ask Hermes to switch: on Telegram/desktop, `/model` (or
   whichever UI's model selector) now lists both IDs; the one you didn't pick
   stays unloaded until requested.

## Why only one model loads at a time by default

`ttl: 600` unloads a model after 10 minutes of inactivity, and by default
llama-swap only keeps **one** model resident at a time — switching models
means a short delay (the new `llama-server` process has to start and load
the GGUF) while the previous one is freed. This matches the modest hardware
both configurations target (an 8 GB VPS, a CPU-only fallback); it is not a
llama-swap limitation. If your Mac has plenty of RAM and you want two models
warm simultaneously, see llama-swap's `groups` setting (not used by the
`models.yaml.example` in this repo) —
[configuration guide](https://github.com/mostlygeek/llama-swap/blob/main/docs/kb/guides/configuration/configuration-overview.md).

## Removing a model

Delete its entry from `models.yaml` (and its `.gguf` from `./models/` if you
want the disk space back). If it happens to be the one currently loaded,
llama-swap unloads it on the next request for anything else.

## Renaming the default

Hermes's `model.default` in `data/config.yaml` (or `./data/config.yaml` on
the VPS) must match a model ID in `models.yaml` **exactly** — this repo uses
`llama-3.1-8b-instruct` in both files by convention. Change both together;
a mismatch here is the most common way to end up with Hermes reporting a
model-not-found error even though `models.yaml` looks correct.

## Inspecting what's running

Both the macOS (`http://127.0.0.1:8080`) and VPS (`http://<vps-ip>:8080`,
tunnel it, don't expose it) llama-swap endpoints serve a small web UI at
`/ui` — a live view of loaded models, logs, and a chat playground to test a
model directly without going through Hermes at all. Useful for telling apart
"Hermes is broken" from "the model itself is broken."

## Sources

- llama-swap — official repository and configuration reference: [github.com/mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
- Hermes `custom` provider and named providers: [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
