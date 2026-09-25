defmodule Ytm.Leds.Strip do
  @moduledoc """
  Registers the LED strip with Fledex's `Fledex.Animation.Manager` and lights
  every led in a single static color, at the configured brightness. See
  `Ytm.Leds` for the configuration.

  Brightness is applied in the driver, as the `:color_correction` scale of the
  SPI driver, so led definitions can keep using full-intensity colors.

  The strip is unregistered (and its SPI device closed) when this process
  terminates.
  """

  use GenServer

  alias Fledex.Animation.Manager
  alias Fledex.Color.Correction
  alias Fledex.Driver.Impl.Null
  alias Fledex.Leds

  @strip_name :ytm_strip
  @default_count 149
  @default_brightness 50
  @color 0xFFFFFF

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  The name of the strip in Fledex, e.g. for `Fledex.Supervisor.AnimationSystem`.
  """
  @spec strip_name() :: atom()
  def strip_name(), do: @strip_name

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)

    count = Keyword.get(config, :count, @default_count)
    brightness = Keyword.get(config, :brightness, @default_brightness)
    driver = driver(Keyword.get(config, :driver, Null), count, brightness)

    :ok = Manager.register_strip(@strip_name, [driver], [])

    :ok =
      Manager.register_config(@strip_name, %{
        base: %{
          type: :static,
          def_func: fn _triggers -> Leds.leds(count) |> Leds.light(@color, repeat: count) end,
          options: [],
          effects: []
        }
      })

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Manager.unregister_strip(@strip_name)
  catch
    # The animation system is already gone (e.g. it's what crashed).
    :exit, _reason -> :ok
  end

  defp driver({module, driver_config}, count, brightness) do
    scale = round(255 * brightness / 100)

    correction =
      Correction.define_correction(
        scale,
        Correction.Color.uncorrected_color(),
        Correction.Temperature.uncorrected_temperature()
      )

    # Blank the whole strip on (re)start, so no leds are left over from before.
    {module,
     driver_config
     |> Keyword.put_new(:color_correction, correction)
     |> Keyword.put_new(:clear_leds, count)}
  end

  defp driver(module, count, brightness), do: driver({module, []}, count, brightness)
end
