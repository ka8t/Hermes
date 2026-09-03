# GPU support for the Linux VPS path (issue #13)

**Status: implemented, not live-verified.** Written and code-reviewed
without any GPU-equipped machine available to test against — this repo's
own reference VPS and every box used in this session's live testing are
CPU-only. Every claim below is sourced (official docs, or the vendor's
own image registry), not guessed, but no end-to-end path has actually
been run. If you have (or rent) a GPU VPS — NVIDIA, AMD, or Intel — please
run through the matching section and report back what actually happens,
see "Verify" in each.

The default path documented everywhere else in this repo (`provision.sh`,
`docker-compose.yml`) is CPU-only, and stays the default. This page covers
three **opt-in** alternatives, one per GPU vendor
[`mostlygeek/llama-swap`](https://github.com/mostlygeek/llama-swap/pkgs/container/llama-swap)
publishes an image for: `:cuda` (NVIDIA), `:rocm` (AMD), `:intel` (Intel).
`provision.sh` detects which vendor (if any) is present and points here —
it does not switch configuration automatically, since each path needs a
host-level prerequisite this repo can't install or verify for you.

`config/models.yaml.example.gpu` is shared across all three vendors — it
only adds `--n-gpu-layers ${env.LLAMA_GPU_LAYERS}` to the `llama-server`
command line, llama.cpp's own GPU-offload flag, identical across its
CUDA/ROCm/SYCL backends (already used on the macOS path as `-ngl 99`, see
[`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md)'s macOS topology).
`LLAMA_GPU_LAYERS` defaults to `99` in `.env.example` (offload every
layer). Only the Docker Compose overlay (image + device access) differs
per vendor, below.

## NVIDIA

**Prerequisites**: an NVIDIA GPU with its driver already working (confirm
with `nvidia-smi` before touching Docker at all), plus the **NVIDIA
Container Toolkit** installed and configured for Docker — this repo does
not install it for you. Follow NVIDIA's own guide:
[docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

```bash
cp config/models.yaml.example.gpu data/models.yaml
docker compose -f docker-compose.yml -f docker-compose.gpu-nvidia.yml up -d
```

`docker-compose.gpu-nvidia.yml` switches the image to
`ghcr.io/mostlygeek/llama-swap:cuda` (confirmed to exist on the project's
own GHCR registry) and requests a GPU via Compose's standard
device-reservation syntax — the Compose-file equivalent of the
`--runtime nvidia` flag shown in `mostlygeek/llama-swap`'s own README for
a plain `docker run` example.

**Verify**:
```bash
docker compose exec llama-swap nvidia-smi   # should list llama-server
./scripts/verify-inference.sh               # tok/s should jump sharply vs.
                                             # the CPU numbers in hardware-sizing.md
```

## AMD (ROCm)

**Prerequisites**: an AMD GPU with ROCm-compatible drivers already
working on the host. Unlike NVIDIA, **no separate container toolkit is
strictly required** — AMD's own docs describe plain device passthrough
(`/dev/kfd`, `/dev/dri`) as sufficient; an optional AMD Container Runtime
Toolkit exists only for fine-grained multi-GPU selection.

```bash
cp config/models.yaml.example.gpu data/models.yaml
docker compose -f docker-compose.yml -f docker-compose.gpu-amd.yml up -d
```

`docker-compose.gpu-amd.yml` switches the image to
`ghcr.io/mostlygeek/llama-swap:rocm` and passes through `/dev/kfd` (the
ROCm compute interface, shared by all GPUs) and `/dev/dri` (the DRI
device nodes) — AMD's own documented manual-passthrough method.

**Verify**:
```bash
docker compose exec llama-swap rocm-smi     # should list llama-server
./scripts/verify-inference.sh               # tok/s should jump sharply vs.
                                             # the CPU numbers in hardware-sizing.md
```

## Intel

**Prerequisites**: an Intel GPU (integrated or Arc/Data Center) with
working drivers. Run `ls -la /dev/dri` first — you should see `renderD1xx`
and `cardN` device nodes.

```bash
cp config/models.yaml.example.gpu data/models.yaml
docker compose -f docker-compose.yml -f docker-compose.gpu-intel.yml up -d
```

`docker-compose.gpu-intel.yml` switches the image to
`ghcr.io/mostlygeek/llama-swap:intel` and maps the whole `/dev/dri`
directory. llama.cpp's own official SYCL Docker docs map specific nodes
instead (e.g. `/dev/dri/renderD128:/dev/dri/renderD128`,
`/dev/dri/card0:/dev/dri/card0`) — this repo maps the whole directory for
portability across machines with different node numbers, since there's no
Intel GPU available here to confirm which approach the `:intel`
llama-swap image actually needs. If the whole-directory mapping doesn't
work, try the exact per-node form from llama.cpp's docs instead (see
Sources).

**Verify**:
```bash
./scripts/verify-inference.sh   # tok/s should jump vs. the CPU numbers
                                 # in hardware-sizing.md
```

## Rough throughput expectation

GPU offload of a model this size typically means tens to low hundreds of
tok/s versus the ~20 tok/s CPU-only measured on this repo's own reference
VPS (see `shared/hardware-sizing.md`) — but that comparison is general
knowledge of GPU vs. CPU inference speedups, not measured on any of the
three setups above, so treat it as a rough expectation, not a guarantee.

## Troubleshooting

Not yet populated for any of the three vendors — this section fills in
once someone actually runs one of these against real hardware and
reports what broke. Nothing has been observed failing yet because
nothing has been run yet. Please open a comment on issue #13 (or a new
issue) with what you saw, on any vendor.

## Sources

- NVIDIA Container Toolkit install guide (official): [docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- `ghcr.io/mostlygeek/llama-swap` image tags (official GHCR package page, confirmed live: `cuda`, `rocm`, `intel` variants exist alongside `cpu`): [github.com/mostlygeek/llama-swap/pkgs/container/llama-swap](https://github.com/mostlygeek/llama-swap/pkgs/container/llama-swap)
- `mostlygeek/llama-swap` NVIDIA `docker run` example (official README): [github.com/mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)
- Docker Compose GPU device reservation syntax (official Compose docs, exact YAML block confirmed): [docs.docker.com/compose/how-tos/gpu-support/](https://docs.docker.com/compose/how-tos/gpu-support/)
- AMD ROCm Docker access — device passthrough vs. optional toolkit (official AMD docs): [rocm.docs.amd.com/projects/install-on-linux/en/latest/how-to/docker.html](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/how-to/docker.html)
- llama.cpp Docker with SYCL (Intel GPU) — official device-mapping example: [github.com/ggml-org/llama.cpp/blob/master/docs/docker.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- llama.cpp `--n-gpu-layers` flag: same source already cited in [`shared/prebuilt-binaries.md`](prebuilt-binaries.md) for this repo's CPU-path flags.
