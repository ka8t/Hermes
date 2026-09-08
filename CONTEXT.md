# Context

Project-level context and working decisions not obvious from reading the
code alone. See `docs/adr/` for the reasoning behind individual
architecture decisions; this file is the lighter-weight, evolving
counterpart — created lazily as real decisions get made (see
`docs/agents/domain.md`).

## Development workflow: Mac first, then VPS

Changes that touch Hermes's runtime behavior (SOUL.md patches,
`docker-compose.yml`, `provision.sh`, gateway/session logic) get
validated on the macOS deployment first, then deployed to the VPS —
not the other way around, and not developed against both
simultaneously.

**Why**: the Mac gives fast local feedback — Metal-accelerated
inference means a retest takes seconds to low minutes. The VPS is
CPU-only; the same retest there can take 20-40+ minutes just for the
first reply's prefill (see `shared/hardware-sizing.md`), which makes it
a poor place to iterate. The VPS is also Docker-only (see
`docs/adr/0001-vps-docker-only.md`), which further narrows it to a
single deployment target to validate against once a fix already works
locally.

**How this applies**: fix → validate on the Mac (Docker or native,
whichever the change targets) → only then apply the same fix to the VPS
and confirm it there too. Skipping straight to the VPS for a first test
is the wrong order — it costs the slow feedback loop for no benefit,
since the Mac would have caught most bugs already.
