defmodule Ytm.CardButton.Supervisor do
  @moduledoc """
  Starts one supervised `Ytm.CardButton.Server` per configured
  `{pin, bus_name}` pair, so each pull-up card-insertion button gets its own
  GPIO handle that reconnects automatically after failures.

  Buttons are read from `config :ytm, #{inspect(__MODULE__)}, buttons: [...]`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    buttons = Application.get_env(:ytm, __MODULE__, [])[:buttons] || []

    children =
      Enum.map(buttons, fn {pin, _bus_name} = button ->
        Supervisor.child_spec({Ytm.CardButton.Server, button}, id: {Ytm.CardButton.Server, pin})
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
