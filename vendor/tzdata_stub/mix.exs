defmodule TzdataStub.MixProject do
  # Empty stand-in for the `:tzdata` application.
  #
  # `fledex_scheduler` (pulled in by `fledex`) declares `:tzdata` as an optional
  # dependency but still lists it in its `extra_applications`, so an app named
  # `:tzdata` must exist for `:ytm` to start and for the release to build. The
  # real package bundles ~3 MB of timezone data, which pushes the firmware over
  # its size limit, and it's never used: nothing sets it as Elixir's
  # `:time_zone_database`, so Fledex's scheduling only ever sees UTC.
  #
  # If a non-UTC timezone is ever needed, replace this with the real
  # `{:tzdata, "~> 1.1"}` dependency (and make room for it in the firmware).
  use Mix.Project

  def project() do
    [app: :tzdata, version: "1.2.1", elixir: "~> 1.15", deps: []]
  end

  def application() do
    []
  end
end
