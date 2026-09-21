defmodule Ytm.PN532.Supervisor do
  @moduledoc """
  Starts one supervised `Ytm.PN532.Server` per configured SPI bus, so
  multiple processes can share a PN532 connection instead of each opening
  its own raw SPI handle, and it reconnects automatically after failures
  or crashes.

  Buses are read from `config :ytm, #{inspect(__MODULE__)}, buses: [...]`.
  The `Registry` used to look servers up by bus name is started as the
  first child under `:rest_for_one`: if it ever crashes, its registrations
  are lost, so the `Server`s (which only register once, at `start_link`)
  must restart alongside it rather than being silently orphaned.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    buses = Application.get_env(:ytm, __MODULE__, [])[:buses] || []

    children =
      [{Registry, keys: :unique, name: Ytm.PN532.Registry}] ++
        Enum.map(buses, fn bus_name ->
          Supervisor.child_spec({Ytm.PN532.Server, bus_name}, id: {Ytm.PN532.Server, bus_name})
        end)

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
