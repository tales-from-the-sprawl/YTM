defmodule Ytm.CardButton.Server do
  @moduledoc """
  Watches one GPIO wired to a pull-up push button that closes to ground when
  a card is inserted into the NFC reader on `bus_name`, and broadcasts a
  `{:card_button_pressed, bus_name}` message on `#{inspect(__MODULE__)}.topic/0`
  over `Ytm.PubSub` for each falling edge, debounced.

  Reconnection is always-on and has no manual override, mirroring
  `Ytm.PN532.Server`: a GPIO that fails to open (or a bus error) is retried on
  `@retry_interval_ms` forever.
  """

  use GenServer

  alias Circuits.GPIO

  require Logger

  @retry_interval_ms 5_000
  @debounce_ms 200
  @topic "nfc:card_button"

  @type status :: :connected | :disconnected

  @type t :: %__MODULE__{
          pin: non_neg_integer(),
          bus_name: String.t(),
          gpio: GPIO.Handle.t() | nil,
          status: status(),
          error: term(),
          last_pressed_at: integer() | nil
        }

  @enforce_keys [:pin, :bus_name]
  defstruct pin: nil,
            bus_name: nil,
            gpio: nil,
            status: :disconnected,
            error: nil,
            last_pressed_at: nil

  @spec start_link({non_neg_integer(), String.t()}) :: GenServer.on_start()
  def start_link({pin, bus_name}) do
    GenServer.start_link(__MODULE__, {pin, bus_name})
  end

  @doc "PubSub topic broadcasting `{:card_button_pressed, bus_name}` for every configured button."
  @spec topic() :: String.t()
  def topic(), do: @topic

  @impl GenServer
  def init({pin, bus_name}) do
    Logger.metadata(card_button_pin: pin, card_button_bus: bus_name)
    {:ok, %__MODULE__{pin: pin, bus_name: bus_name}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_info(:retry_connect, state), do: {:noreply, attempt_connect(state)}

  def handle_info(
        {:circuits_gpio, %{ref: bus_name, value: 0}},
        %__MODULE__{bus_name: bus_name} = state
      ) do
    {:noreply, maybe_broadcast_press(state)}
  end

  def handle_info({:circuits_gpio, %{}}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.gpio, do: GPIO.close(state.gpio)
    :ok
  end

  defp attempt_connect(state) do
    case open_and_subscribe(state.pin, state.bus_name) do
      {:ok, gpio} ->
        Logger.info("connected")
        %{state | gpio: gpio, status: :connected, error: nil}

      {:error, reason} ->
        if state.status == :connected do
          Logger.warning("lost connection: #{inspect(reason)}")
        end

        Process.send_after(self(), :retry_connect, @retry_interval_ms)
        %{state | gpio: nil, status: :disconnected, error: reason}
    end
  end

  defp open_and_subscribe(pin, bus_name) do
    with {:ok, gpio} <- GPIO.open(pin, :input, pull_mode: :pullup),
         {:ok, _ref} <- GPIO.subscribe(gpio, trigger: :falling, tag: bus_name) do
      {:ok, gpio}
    else
      {:error, reason} = error ->
        Logger.error("failed to arm button: #{inspect(reason)}")
        error
    end
  end

  defp maybe_broadcast_press(state) do
    now = System.monotonic_time(:millisecond)

    if state.last_pressed_at == nil or now - state.last_pressed_at >= @debounce_ms do
      Logger.info("pressed")
      Phoenix.PubSub.broadcast(Ytm.PubSub, @topic, {:card_button_pressed, state.bus_name})
      %{state | last_pressed_at: now}
    else
      state
    end
  end
end
