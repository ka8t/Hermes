# Using official prebuilt binaries (llama.cpp)

See also: [Glossary](../docs/GLOSSARY.md) for acronyms/technical terms used below.

Both configurations in this repo default to prebuilt, ready-to-run binaries
rather than compiling anything — faster to get going, and doesn't require a
compiler toolchain at all. This note documents what's actually in them
(verified by downloading and inspecting the archives/images, 2026-09-02) and
how each platform folder uses them.

## llama.cpp (`llama-server`)

### Where the binaries live

Releases are at <https://github.com/ggml-org/llama.cpp/releases>, but the
top "latest" release is a stable-looking tag (e.g. `v0.3.0`) that carries
**no binaries** — just a `nightly-tag.txt` pointer. The actual binaries ship
under **rolling build-numbered tags** (`b10753`, `b10754`, ...), one per CI
build, each holding the real assets:

```
llama-<tag>-bin-macos-arm64.tar.gz      # macOS, Apple Silicon
llama-<tag>-bin-macos-x64.tar.gz        # macOS, Intel
llama-<tag>-bin-ubuntu-x64.tar.gz       # Linux x86-64, CPU only
llama-<tag>-bin-ubuntu-arm64.tar.gz     # Linux ARM64, CPU only
llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz
llama-<tag>-bin-ubuntu-rocm-*.tar.gz
llama-<tag>-bin-win-*.zip
...
```

Because the tag changes on every build, hardcoding one (e.g. `b10753`) goes
stale almost immediately — `macos-arm64/scripts/download-prebuilt-llama-server.sh`
instead queries the GitHub API for the newest release that contains the
asset it needs:

```bash
curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases" \
  | grep -oE '"browser_download_url": *"[^"]*bin-macos-arm64\.tar\.gz"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)"/\1/'
```

The VPS has the equivalent
`linux-x86_64-vps/scripts/download-prebuilt-llama-server.sh` (same
approach, targets `bin-ubuntu-x64.tar.gz`), fetching the binary into
`./vendor/llama.cpp-prebuilt` where `docker-compose.yml` bind-mounts it
into the `llama-server` container — see `docs/ARCHITECTURE.md`,
2026-09-15 (before that, the VPS got `llama-server` bundled inside the
`ghcr.io/mostlygeek/llama-swap:cpu` image instead; issue #101 covers why
that changed).

### What's actually inside (verified)

- **`bin-macos-arm64.tar.gz`** ships `libggml-metal.dylib` — **Metal
  acceleration is built in**, no separate GPU build needed on Apple Silicon.
- **`bin-ubuntu-x64.tar.gz`** ships one `libggml-cpu-<microarch>.so`
  per CPU generation (`haswell`, `skylakex`, `icelake`, `sapphirerapids`,
  `zen4`, ...) — `llama-server` picks the best one for the actual CPU at
  startup, so there's no need to compile with `-march=native` yourself. This
  is **CPU-only**; GPU variants (`ubuntu-vulkan-*`, `ubuntu-rocm-*`) are
  separate downloads, not needed for the small CPU-only VPS this repo
  targets.
- The macOS archive includes `llama-server` alongside other CLI tools and
  their shared libraries (`.dylib`), which `llama-server` loads from its own
  directory at startup — **run it from inside the extracted folder** (or
  keep the whole folder together), don't copy just the binary out on its
  own. `download-prebuilt-llama-server.sh` already does this correctly.
- Downloading with `curl` from a terminal does **not** trigger macOS
  Gatekeeper's quarantine flag (that only applies to files quarantined by a
  browser or Finder); if you instead drag a downloaded archive through the
  Finder, clear it with `xattr -dr com.apple.quarantine <folder>` before
  running the binary.

## Trust considerations (reviewed, not overlooked)

Every binary this repo runs — `llama-server` and the
`nousresearch/hermes-agent`-derived `ghcr.io/ka8t/hermes` image — is
built by each project's own CI, not signed with a personal or
organizational GPG key, and not notarized (on macOS). Using them means
trusting those projects' build pipelines with full access to the
machine they run on. This was weighed explicitly (not an oversight):
the alternative, building everything from source, doesn't remove the
trust dependency on the *source code* itself, only on the *binary
supply chain* on top of it, and this repo's default posture accepts
that remaining risk for the convenience of not maintaining a compiler
toolchain. Anyone who wants the stricter posture can still build
llama.cpp from source — see `find-or-build-llama-server.sh`'s
from-source fallback (`LLAMA_BUILD_FROM_SOURCE=1`).

## Trade-off vs. building from source

| | Prebuilt binary | Build from source |
|---|---|---|
| Setup time | Seconds (download + extract) | Minutes (compiler + build) |
| Toolchain required | None (just `curl`/`tar`) | CMake + a C++ compiler |
| CPU/GPU tuning | Generic (auto-dispatch on Linux, default Metal on Mac) | Can target your exact CPU/GPU flags |
| Freshness | One official CI build behind at most | Whatever commit you choose |
| Supply-chain trust | Trusts the project's CI-built binary | Trusts the project's source, not its CI |

macOS tries the prebuilt binary **first** and only falls back to building
from source if asked — see `scripts/find-or-build-llama-server.sh`
(`LLAMA_BUILD_FROM_SOURCE=1` to force it).
