# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ytm` (module prefix `Ytm`/`YtmWeb`) is a Nerves + Phoenix LiveView kiosk application. It runs a
full-screen Phoenix LiveView app on a Raspberry Pi, rendered by the Cog WebKit browser directly to
DRM (no X11/Wayland compositor). The home screen shows system info, IPs, a GPIO control page, and
Phoenix LiveDashboard. It's based on/related to `nerves-web-kiosk/kiosk_demo`.

The app targets two very different runtimes from one codebase:
- **`:host`** — plain BEAM/Phoenix, for local development in a browser, no hardware.
- **`:rpi4`** (Nerves target) — cross-compiled firmware image running on real hardware.

Which one you're building for is controlled by `Mix.target()` / the `MIX_TARGET` env var, and a lot
of code branches on it at compile time (`if Mix.target() == :host do ... else ... end`).

## Commands

Toolchain is pinned via `mise.toml` (Elixir 1.20.4-otp-29, Erlang 29.0.6, fwup). Use `mise` to get
the right versions, or ensure your local Elixir/OTP match.

### Host development (default; no hardware needed)

```sh
mix setup          # deps.get + assets.setup + assets.build
mix phx.server      # run at http://localhost:4000
```

Hardware-specific features (GPIO, Cog/D-Bus, udev) are not functional on `:host`.

### Target/firmware (Raspberry Pi 4)

```sh
export MIX_TARGET=rpi4
mix setup
mix firmware        # build firmware
mix burn             # write to MicroSD
```

Also available via mise tasks (already set `MIX_TARGET=rpi4`): `mise run firmware`,
`mise run upload`, `mise run reload` (hot-swaps code onto a running device via
`mix_tasks_upload_hotswap`, uses `upload.sh`).

SSH into a running device: `ssh ytm@nerves.local` (key-based, no password) drops straight into an
IEx console on the device. `nerves.local` is the default mDNS hostname (see `upload.sh`/
`mise.toml`); use the device's actual hostname/IP if mDNS isn't resolving. `mix upload.hotswap`
(the `mise run reload` task) can push recompiled `.beam` files to a running device over this same
distributed-Erlang connection without a full firmware rebuild — handy for iterating on a bug and
verifying the fix against real hardware before committing to a `mix firmware`/`mix burn` cycle.

### Tests, formatting, linting

```sh
mix test                                  # runs on :host target (see `preferred_target` in mix.exs)
mix test test/path/to/file_test.exs       # single file
mix test test/path/to/file_test.exs:23    # single test at line
mix format                                # format .ex/.exs/.heex per .formatter.exs
mix credo --strict                        # lint lib/ (see .credo.exs; excludes lib/ytm_web/)
mix dialyzer                               # type checking (see dialyzer() in mix.exs)
mix precommit                              # alias: compile --warnings-as-errors, deps.unlock --unused, format, test
```

Run `mix precommit` before considering a change done — it's the project's defined gate.

Note: `mix test`/`mix run` default to the `:host` target regardless of `MIX_TARGET` (see
`preferred_target` in `mix.exs`), so tests don't require cross-compilation or hardware.

## Architecture

### Compile-time target branching

`lib/ytm/application.ex` defines two completely different supervision trees based on
`Mix.target()`:
- `:host` — only the Phoenix children (`YtmWeb.Telemetry`, `DNSCluster`, `Phoenix.PubSub`,
  `YtmWeb.Endpoint`).
- everything else (i.e. `:rpi4`) — the same Phoenix children plus `Ytm.UdevdServer`,
  `Ytm.KioskSupervisor`, and a task that starts distribution/EPMD for hot code upload.

Config is layered the same way: `config/config.exs` holds Nerves-wide config (vintage_net, mdns,
ssh keys, shoehorn) and ends with `import_config "#{Mix.target()}.exs"`; `config/host.exs` stubs
out an in-memory `Nerves.Runtime.KV` and disables udev management so hardware-free code paths work;
`config/rpi4.exs` and `config/phoenix/*.exs` (`config.exs`, `dev.exs`, `docs.exs`, `prod.exs`,
`test.exs`) hold the rest.

When adding a feature that touches hardware (GPIO, D-Bus, network config), guard it the same way
existing code does — check `Code.ensure_loaded?/1` or `Mix.target()` — so it degrades gracefully on
`:host`, and add corresponding host-side config/stubs rather than making the module crash when the
hardware isn't present.

### Kiosk display pipeline (target-only)

`Ytm.KioskSupervisor` (a `:rest_for_one` supervisor, so if `dbus` dies, `cog` restarts too) starts,
in order:
1. A private session `dbus-daemon` (fixes cookie/UID quirks for running as root under Nerves).
2. The `cog` WebKit browser (via `MuonTrap.Daemon`), pointed at `http://localhost:4000/`,
   rendering full-screen through DRM/GLES. It waits for the D-Bus socket and a `/dev/dri/cardN`
   device to appear before launching (polling, with retry limits).

`Ytm.Cog` is a D-Bus client for controlling the running Cog browser instance (navigate/back/
forward/reload/quit) by calling `org.gtk.Actions.Activate` on `com.igalia.Cog` over the session
bus set up above.

`Ytm.UdevdServer` runs `udevd` and triggers/settles udev so device nodes (like `/dev/dri/cardN`)
exist before Cog starts.

### NFC reader (`Ytm.PN532`)

`Ytm.PN532` (`lib/ytm/pn532.ex`) is a from-scratch SPI driver for the PN532 NFC/RFID IC (a port of
Adafruit's CircuitPython `adafruit_pn532` SPI backend; see NXP UM0701-02), built on
`Ytm.PN532.SPI` (bus transport) and `Ytm.PN532.Frame` (host-controller-interface framing). It's a
stateless module — `open/2` returns a `%Ytm.PN532{}` wrapping a `Circuits.SPI` handle, and there's
no supervised connection/detection process, so callers own opening, polling, and closing it
themselves (see `YtmWeb.NFCLive` below).

`read_ndef/3` reads a detected tag's NDEF message, dispatching on its SAK (from
`get_passive_target/2`/`read_passive_target/3`, which return `{uid, sak}`): NTAG21x/Ultralight
tags (NFC Forum Type 2, SAK `0x00`) are read via unauthenticated paged reads starting at page 4;
Mifare Classic-compliant tags (SAK bit 3 set, e.g. `0x08` for Classic 1K) go through
`mifare_classic_read_ndef/2`, which authenticates sector 0 with the well-known MAD key
(`A0A1A2A3A4A5`) to parse the MAD (Mifare Application Directory) for sectors marked with the NDEF
application id, then authenticates and reads each of those sectors with the well-known NDEF key
(`D3F7D3F7D3F7`), skipping trailer blocks. Only the single-MAD, 16-sector Classic 1K layout is
supported (no MAD2/4K). `Ytm.NDEF` (`lib/ytm/ndef.ex`) then unwraps the NFC Forum Type 2 Tag TLV
block structure and decodes NDEF records, with helpers for the well-known Text and URI types.

Note that a card's SAK alone doesn't guarantee which key scheme a Classic-compliant tag actually
uses — `A0A1A2A3A4A5`/`D3F7D3F7D3F7` are just the NFC Forum/NXP-documented defaults for
MAD+NDEF-formatted cards, not something the protocol enforces.

### Web app (`lib/ytm_web`)

Standard Phoenix/LiveView structure. Routes (`router.ex`): `/` (`HomeLive`), `/dashboard`
(`DashboardLive`), `/gpio` (`GPIOLive`), `/nfc` (`NFCLive`), `/loading` (plain controller), and
`/dev/dashboard` (Phoenix LiveDashboard). `GPIOLive` opens/reads/writes `Circuits.GPIO` pins
directly, and `NFCLive` opens/closes `Ytm.PN532` connections on both SPI0 chip-selects
(`spidev0.0`/`spidev0.1`) directly, the same "LiveView owns the hardware handle for its own
lifetime, closed in `terminate/2`" pattern in both cases — only meaningful on target; GPIO
enumeration and SPI bus access return empty/errors on host.

Assets: Tailwind + esbuild via the `:tailwind`/`:esbuild` Mix deps (no Node/npm build step), driven
by the `assets.setup`/`assets.build`/`assets.deploy` aliases in `mix.exs`. Icons come from the
`heroicons` dep pulled straight from GitHub.

### Licensing

This repo is REUSE-compliant (`REUSE.toml` + SPDX headers); most first-party files are
`CC0-1.0`/no-copyright. Keep new files consistent with the annotations in `REUSE.toml` if adding
license headers.

## Code style notes

- `lib/ytm_web/` is excluded from Credo (`.credo.exs`); `lib/` (i.e. `Ytm.*` context/hardware code)
  is linted with `strict: true` and requires `@spec` on public functions (see `Ytm.Cog`,
  `Ytm.KioskSupervisor` for the pattern: `@spec` above each public function, module attributes for
  constants).
- Formatting includes `.heex` templates (`Phoenix.LiveView.HTMLFormatter` plugin) and the
  `rootfs_overlay/etc/iex.exs` file — see `.formatter.exs` for the full `inputs` list.
