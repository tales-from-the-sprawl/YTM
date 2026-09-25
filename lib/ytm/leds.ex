defmodule Ytm.Leds do
  @moduledoc """
  Supervises the NeoPixel (WS2812) LED strip, driven by the `Fledex` library.

  Starts Fledex's `Fledex.Supervisor.AnimationSystem` (animation manager, its
  PubSub and the led strip servers) followed by `Ytm.Leds.Strip`, which
  registers our strip and what to show on it. `:rest_for_one`, so if the
  animation system restarts the strip is registered again.

  Configured with `config :ytm, #{inspect(__MODULE__)}, [...]`:

  * `:driver`: a Fledex driver module, or `{module, config}` tuple (default:
    `Fledex.Driver.Impl.Null`, i.e. no hardware, as on host).
  * `:count`: number of leds on the strip (default: `149`).
  * `:brightness`: overall brightness in percent, `1..100` (default: `50`).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    config = Application.get_env(:ytm, __MODULE__, [])

    children = [
      Fledex.Supervisor.AnimationSystem,
      {Ytm.Leds.Strip, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
