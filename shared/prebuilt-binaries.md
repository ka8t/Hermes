# Using llama.cpp's official prebuilt binaries

Both configurations in this repo default to something that "just runs" —
Hermes always as a Docker image, and llama.cpp either as a Docker image (VPS)
or built from source (Mac). But `ggml-org/llama.cpp` also publishes
**ready-to-run binaries** for every commit, which is faster to get going than
building from source and doesn't require a compiler toolchain at all. This
note documents what's actually in them (verified by downloading and
inspecting the archives, 2026-09-02) and how each platform folder uses them.

## Where they live

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
stale almost immediately — both `download-prebuilt-llama-server.sh` scripts
in this repo instead query the GitHub API for the newest release that
contains the asset they need:

```bash
curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases" \
  | grep -oE '"browser_download_url": *"[^"]*bin-macos-arm64\.tar\.gz"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)"/\1/'
```

(swap `bin-macos-arm64` for `bin-ubuntu-x64` on Linux).

## What's actually inside (verified)

- **`bin-macos-arm64.tar.gz`** ships `libggml-metal.dylib` — **Metal
  acceleration is built in**, no separate GPU build needed on Apple Silicon.
- **`bin-ubuntu-x64.tar.gz`** ships one `libggml-cpu-<microarch>.so` per CPU
  generation (`haswell`, `skylakex`, `icelake`, `sapphirerapids`, `zen4`,
  ...) — `llama-server` picks the best one for the actual CPU at startup, so
  there's no need to compile with `-march=native` yourself. This archive is
  **CPU-only**; GPU variants (`ubuntu-vulkan-*`, `ubuntu-rocm-*`) are separate
  downloads, not needed for the small CPU-only VPS this repo targets.
- Both archives include `llama-server` alongside the other CLI tools and
  their shared libraries (`.dylib` / `.so`), which `llama-server` loads from
  its own directory at startup — **run it from inside the extracted folder**
  (or keep the whole folder together), don't copy just the binary out on its
  own.
- Downloading with `curl` from a terminal does **not** trigger macOS
  Gatekeeper's quarantine flag (that only applies to files quarantined by a
  browser or Finder); if you instead drag a downloaded archive through the
  Finder, clear it with `xattr -dr com.apple.quarantine <folder>` before
  running the binary.

## Trade-off vs. building from source

| | Prebuilt binary | Build from source |
|---|---|---|
| Setup time | Seconds (download + extract) | Minutes (compiler + build) |
| Toolchain required | None (just `curl`/`tar`) | CMake + a C++ compiler |
| CPU/GPU tuning | Generic (auto-dispatch on Linux, default Metal on Mac) | Can target your exact CPU/GPU flags |
| Freshness | One official CI build behind at most | Whatever commit you choose |

Both platform folders in this repo try the prebuilt binary **first** and
only fall back to building from source if you explicitly ask for it — see
each platform's `scripts/find-or-build-llama-server.sh` (macOS) or
`scripts/download-prebuilt-llama-server.sh` (VPS).
